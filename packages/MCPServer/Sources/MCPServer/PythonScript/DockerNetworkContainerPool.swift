import Foundation

/// Result of a `docker` CLI invocation used by the container pool.
public struct DockerCLIResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public typealias DockerCLIExecutor = @Sendable (_ arguments: [String], _ timeoutSeconds: Int) async throws -> DockerCLIResult

/// Queued Docker pools: network (max 2, 1 warm standby) and offline (max 1, on-demand only).
public actor DockerNetworkContainerPool {
    public static let shared = DockerNetworkContainerPool()

    private struct Slot {
        var warmName: String?
        var inUse = false
        var replenishing = false
    }

    private var networkSlots: [Slot]
    private var offlineSlots: [Slot]
    private var networkWaiters: [CheckedContinuation<Void, Never>] = []
    private var offlineWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        networkSlotCount: Int = DockerScriptPreparer.networkPoolSlotCount,
        offlineSlotCount: Int = DockerScriptPreparer.offlinePoolSlotCount
    ) {
        networkSlots = Array(repeating: Slot(), count: max(1, networkSlotCount))
        offlineSlots = Array(repeating: Slot(), count: max(1, offlineSlotCount))
    }

    /// Ensures one warm networked slot (slot 0) is ready.
    public func prewarm(executor: @escaping DockerCLIExecutor) async throws {
        try await removeLegacyWarmContainers(executor: executor)
        try await ensureNetworkWarmSlot(0, executor: executor)
    }

    /// Runs `operation` with an exclusive container, queued when the relevant pool is at capacity.
    public func withContainer<T: Sendable>(
        allowNetwork: Bool,
        executor: @escaping DockerCLIExecutor,
        _ operation: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        if allowNetwork {
            return try await withNetworkContainer(executor: executor, operation)
        }
        return try await withOfflineContainer(executor: executor, operation)
    }

    // MARK: - Network pool (max 2, 1 warm standby)

    private func withNetworkContainer<T: Sendable>(
        executor: @escaping DockerCLIExecutor,
        _ operation: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        let slotIndex = try await acquireNetwork(executor: executor)
        let name = DockerScriptPreparer.networkPoolContainerName(slotIndex: slotIndex)
        defer {
            Task { await self.releaseNetworkAfterRun(slotIndex: slotIndex, executor: executor) }
        }
        return try await withContainerLeaseTTL {
            try await operation(name)
        }
    }

    private func acquireNetwork(executor: DockerCLIExecutor) async throws -> Int {
        while true {
            if let index = firstAvailableWarmSlot(in: networkSlots) {
                networkSlots[index].inUse = true
                return index
            }
            if let index = firstEmptySlot(in: networkSlots) {
                try await ensureNetworkWarmSlot(index, executor: executor)
                networkSlots[index].inUse = true
                return index
            }
            await withCheckedContinuation { continuation in
                networkWaiters.append(continuation)
            }
        }
    }

    private func releaseNetworkAfterRun(slotIndex: Int, executor: DockerCLIExecutor) async {
        guard networkSlots.indices.contains(slotIndex) else { return }
        let name = DockerScriptPreparer.networkPoolContainerName(slotIndex: slotIndex)
        networkSlots[slotIndex].inUse = false
        networkSlots[slotIndex].warmName = nil
        networkSlots[slotIndex].replenishing = true
        defer {
            networkSlots[slotIndex].replenishing = false
            resumeNetworkWaiters()
        }

        if slotIndex == DockerScriptPreparer.networkPoolStandbySlotIndex {
            do {
                try await recreateNetworkSlot(slotIndex, executor: executor)
            } catch {
                fputs(
                    "[DockerPool] network replenish failed slot=\(slotIndex): \(error.localizedDescription)\n",
                    stderr
                )
            }
            return
        }

        _ = try? await executor(DockerScriptPreparer.dockerRmForceArguments(container: name), 15)
    }

    // MARK: - Offline pool (max 1, queued, no warm standby)

    private func withOfflineContainer<T: Sendable>(
        executor: @escaping DockerCLIExecutor,
        _ operation: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        let slotIndex = try await acquireOffline(executor: executor)
        let name = DockerScriptPreparer.offlinePoolContainerName(slotIndex: slotIndex)
        defer {
            Task { await self.releaseOfflineAfterRun(slotIndex: slotIndex, executor: executor) }
        }
        return try await withContainerLeaseTTL {
            try await operation(name)
        }
    }

    private func acquireOffline(executor: DockerCLIExecutor) async throws -> Int {
        while true {
            if let index = firstIdleOfflineSlot() {
                offlineSlots[index].replenishing = true
                do {
                    try await createOfflineSlot(index, executor: executor)
                    offlineSlots[index].replenishing = false
                    offlineSlots[index].inUse = true
                    return index
                } catch {
                    offlineSlots[index].replenishing = false
                    resumeOfflineWaiters()
                    throw error
                }
            }
            await withCheckedContinuation { continuation in
                offlineWaiters.append(continuation)
            }
        }
    }

    private func releaseOfflineAfterRun(slotIndex: Int, executor: DockerCLIExecutor) async {
        guard offlineSlots.indices.contains(slotIndex) else { return }
        let name = DockerScriptPreparer.offlinePoolContainerName(slotIndex: slotIndex)
        offlineSlots[slotIndex].inUse = false
        offlineSlots[slotIndex].warmName = nil
        offlineSlots[slotIndex].replenishing = true
        defer {
            offlineSlots[slotIndex].replenishing = false
            resumeOfflineWaiters()
        }
        _ = try? await executor(DockerScriptPreparer.dockerRmForceArguments(container: name), 15)
    }

    private func firstIdleOfflineSlot() -> Int? {
        offlineSlots.firstIndex { !$0.inUse && !$0.replenishing }
    }

    // MARK: - Shared helpers

    private func firstAvailableWarmSlot(in slots: [Slot]) -> Int? {
        slots.firstIndex { $0.warmName != nil && !$0.inUse && !$0.replenishing }
    }

    private func firstEmptySlot(in slots: [Slot]) -> Int? {
        slots.firstIndex { $0.warmName == nil && !$0.inUse && !$0.replenishing }
    }

    private func resumeNetworkWaiters() {
        let pending = networkWaiters
        networkWaiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    private func resumeOfflineWaiters() {
        let pending = offlineWaiters
        offlineWaiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    private func ensureNetworkWarmSlot(_ slotIndex: Int, executor: DockerCLIExecutor) async throws {
        guard networkSlots.indices.contains(slotIndex) else { return }
        if networkSlots[slotIndex].warmName != nil, !networkSlots[slotIndex].inUse { return }
        networkSlots[slotIndex].replenishing = true
        defer { networkSlots[slotIndex].replenishing = false }
        try await recreateNetworkSlot(slotIndex, executor: executor)
    }

    private func recreateNetworkSlot(_ slotIndex: Int, executor: DockerCLIExecutor) async throws {
        let name = DockerScriptPreparer.networkPoolContainerName(slotIndex: slotIndex)
        _ = try await executor(DockerScriptPreparer.dockerRmForceArguments(container: name), 15)
        try await createAndStartContainer(
            name: name,
            createArguments: DockerScriptPreparer.dockerCreateNetworkPoolContainerArguments(containerName: name),
            executor: executor
        )
        networkSlots[slotIndex].warmName = name
    }

    private func createOfflineSlot(_ slotIndex: Int, executor: DockerCLIExecutor) async throws {
        let name = DockerScriptPreparer.offlinePoolContainerName(slotIndex: slotIndex)
        _ = try await executor(DockerScriptPreparer.dockerRmForceArguments(container: name), 15)
        try await createAndStartContainer(
            name: name,
            createArguments: DockerScriptPreparer.dockerCreateOfflineContainerArguments(containerName: name),
            executor: executor
        )
        offlineSlots[slotIndex].warmName = name
    }

    private func createAndStartContainer(
        name: String,
        createArguments: [String],
        executor: DockerCLIExecutor
    ) async throws {
        let create = try await executor(createArguments, 30)
        if create.exitCode != 0 {
            let stderr = String(decoding: create.stderr, as: UTF8.self)
            throw DockerNetworkContainerPoolError.createFailed(name, stderr)
        }

        let start = try await executor(DockerScriptPreparer.dockerStartArguments(containerName: name), 30)
        if start.exitCode != 0 {
            let stderr = String(decoding: start.stderr, as: UTF8.self)
            throw DockerNetworkContainerPoolError.startFailed(name, stderr)
        }

        let running = try await executor(
            DockerScriptPreparer.dockerInspectContainerRunningArguments(containerName: name),
            15
        )
        let isRunning = String(decoding: running.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        guard isRunning else {
            throw DockerNetworkContainerPoolError.startFailed(name, "container not running after start")
        }
    }

    private func removeLegacyWarmContainers(executor: DockerCLIExecutor) async throws {
        for legacy in DockerScriptPreparer.legacyWarmContainerNames {
            _ = try? await executor(DockerScriptPreparer.dockerRmForceArguments(container: legacy), 15)
        }
    }

    private func withContainerLeaseTTL<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let maxSeconds = DockerScriptPreparer.containerRunMaxTTLSeconds
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(maxSeconds) * 1_000_000_000)
                throw DockerNetworkContainerPoolError.leaseTTLExceeded(maxSeconds: maxSeconds)
            }
            guard let result = try await group.next() else {
                throw DockerNetworkContainerPoolError.leaseTTLExceeded(maxSeconds: maxSeconds)
            }
            group.cancelAll()
            return result
        }
    }
}

public enum DockerNetworkContainerPoolError: Error, LocalizedError {
    case createFailed(String, String)
    case startFailed(String, String)
    case leaseTTLExceeded(maxSeconds: Int)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let name, let stderr):
            return "Failed to create Docker pool container \(name): \(stderr)"
        case .startFailed(let name, let detail):
            return "Failed to start Docker pool container \(name): \(detail)"
        case .leaseTTLExceeded(let maxSeconds):
            return DockerScriptPreparer.containerLeaseExceededExplanation(maxSeconds: maxSeconds)
        }
    }
}
