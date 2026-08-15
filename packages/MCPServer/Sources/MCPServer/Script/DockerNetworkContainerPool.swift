import Foundation
import DockerRunnerXPC

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

public typealias DockerCLIExecutor = @Sendable (_ arguments: [String], _ stdin: Data, _ timeoutSeconds: Int) async throws -> DockerCLIResult

/// One shared Bun pool: max 3 live containers, 1 warm after prewarm, FIFO across all agents.
public actor DockerNetworkContainerPool {
    public static let shared = DockerNetworkContainerPool()

    private struct Slot {
        var warmName: String?
        var scratchVolume: String?
        var dataVolume: String?
        var inUse = false
        var replenishing = false
    }

    private var slots: [Slot]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(slotCount: Int = DockerScriptPreparer.poolSlotCount) {
        slots = Array(repeating: Slot(), count: max(1, slotCount))
    }

    public func prewarm(executor: @escaping DockerCLIExecutor) async throws {
        try await removeLegacyWarmContainers(executor: executor)
        try await DockerVolumeIO.injectHelpers(exec: executor)
        try await ensureWarmSlot(DockerScriptPreparer.warmStandbySlotIndex, executor: executor)
    }

    /// Recreate the leased container as `--network none` on the same volumes.
    public func handoffToOffline(
        containerName: String,
        executor: @escaping DockerCLIExecutor
    ) async throws {
        guard let slotIndex = DockerScriptPreparer.poolSlotIndex(forContainerName: containerName),
              slots.indices.contains(slotIndex) else {
            let result = try await executor(
                DockerScriptPreparer.dockerNetworkDisconnectArguments(containerName: containerName),
                Data(),
                15
            )
            if result.exitCode != 0 {
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                if !stderr.lowercased().contains("is not connected") && !stderr.lowercased().contains("not found") {
                    throw DockerNetworkContainerPoolError.startFailed(containerName, stderr)
                }
            }
            return
        }
        let scratch = slots[slotIndex].scratchVolume
            ?? DockerScriptPreparer.scratchVolumeName(slotIndex: slotIndex)
        let data = slots[slotIndex].dataVolume
        _ = try? await executor(DockerScriptPreparer.dockerRmForceArguments(container: containerName), Data(), 15)
        try await createAndStartContainer(
            name: containerName,
            createArguments: DockerScriptPreparer.dockerCreateHandoffArguments(
                containerName: containerName,
                scratchVolume: scratch,
                dataVolume: data
            ),
            executor: executor
        )
        slots[slotIndex].warmName = containerName
        slots[slotIndex].scratchVolume = scratch
    }

    public func withContainer<T: Sendable>(
        executor: @escaping DockerCLIExecutor,
        _ operation: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        let slotIndex = try await acquire(executor: executor)
        let name = DockerScriptPreparer.poolContainerName(slotIndex: slotIndex)
        defer {
            Task { await self.releaseAfterRun(slotIndex: slotIndex, executor: executor) }
        }
        return try await withContainerLeaseTTL {
            try await operation(name)
        }
    }

    /// Compatibility wrapper for callers that still pass allowNetwork (ignored).
    public func withContainer<T: Sendable>(
        allowNetwork: Bool,
        executor: @escaping DockerCLIExecutor,
        _ operation: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        _ = allowNetwork
        return try await withContainer(executor: executor, operation)
    }

    private func acquire(executor: DockerCLIExecutor) async throws -> Int {
        let preferred = DockerScriptPreparer.invokeSlotIndex
        while true {
            if slots.indices.contains(preferred),
               !slots[preferred].inUse,
               !slots[preferred].replenishing {
                if slots[preferred].warmName == nil {
                    try await ensureWarmSlot(preferred, executor: executor)
                }
                slots[preferred].inUse = true
                return preferred
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private func releaseAfterRun(slotIndex: Int, executor: DockerCLIExecutor) async {
        guard slots.indices.contains(slotIndex) else { return }
        let name = DockerScriptPreparer.poolContainerName(slotIndex: slotIndex)
        slots[slotIndex].inUse = false
        slots[slotIndex].warmName = nil
        slots[slotIndex].replenishing = true
        defer {
            slots[slotIndex].replenishing = false
            resumeWaiters()
        }

        _ = try? await executor(DockerScriptPreparer.dockerRmForceArguments(container: name), Data(), 15)
        if let scratch = slots[slotIndex].scratchVolume, DerrickNamedVolume.isRemovable(scratch) {
            _ = try? await executor(DockerScriptPreparer.dockerVolumeRmArguments(name: scratch), Data(), 15)
        }
        slots[slotIndex].scratchVolume = nil
        slots[slotIndex].dataVolume = nil

        if slotIndex == DockerScriptPreparer.warmStandbySlotIndex {
            do {
                try await recreateSlot(slotIndex, executor: executor)
            } catch {
                fputs(
                    "[DockerPool] warm replenish failed slot=\(slotIndex): \(error.localizedDescription)\n",
                    stderr
                )
            }
        }
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    private func ensureWarmSlot(_ slotIndex: Int, executor: DockerCLIExecutor) async throws {
        guard slots.indices.contains(slotIndex) else { return }
        if slots[slotIndex].warmName != nil, !slots[slotIndex].inUse { return }
        slots[slotIndex].replenishing = true
        defer { slots[slotIndex].replenishing = false }
        try await recreateSlot(slotIndex, executor: executor)
    }

    private func recreateSlot(_ slotIndex: Int, executor: DockerCLIExecutor) async throws {
        let name = DockerScriptPreparer.poolContainerName(slotIndex: slotIndex)
        let scratch = DockerScriptPreparer.scratchVolumeName(slotIndex: slotIndex)
        _ = try? await executor(DockerScriptPreparer.dockerVolumeCreateArguments(name: DerrickNamedVolume.helpers), Data(), 15)
        _ = try? await executor(DockerScriptPreparer.dockerVolumeCreateArguments(name: scratch), Data(), 15)
        slots[slotIndex].scratchVolume = scratch
        if try await isHealthyWarmContainer(name, executor: executor) {
            slots[slotIndex].warmName = name
            return
        }
        var lastError: Error?
        for attempt in 0..<3 {
            if try await isHealthyWarmContainer(name, executor: executor) {
                slots[slotIndex].warmName = name
                return
            }
            do {
                try await createAndStartContainer(
                    name: name,
                    createArguments: DockerScriptPreparer.dockerCreateWarmContainerArguments(containerName: name),
                    executor: executor
                )
                slots[slotIndex].warmName = name
                return
            } catch {
                lastError = error
                fputs(
                    "[DockerPool] warm create attempt \(attempt + 1) failed name=\(name): \(error.localizedDescription)\n",
                    stderr
                )
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw lastError ?? DockerNetworkContainerPoolError.startFailed(name, "container not running after start")
    }

    private func createAndStartContainer(
        name: String,
        createArguments: [String],
        executor: DockerCLIExecutor
    ) async throws {
        _ = try await executor(DockerScriptPreparer.dockerRmForceArguments(container: name), Data(), 15)

        let create = try await executor(createArguments, Data(), 30)
        if create.exitCode != 0 {
            let stderr = String(decoding: create.stderr, as: UTF8.self)
            // UI and derrickd both prewarm this name — adopt if the other side won.
            if try await isHealthyWarmContainer(name, executor: executor) {
                return
            }
            throw DockerNetworkContainerPoolError.createFailed(name, stderr)
        }

        let start = try await executor(DockerScriptPreparer.dockerStartArguments(containerName: name), Data(), 30)
        if start.exitCode != 0 {
            if try await isHealthyWarmContainer(name, executor: executor) {
                return
            }
            let stderr = String(decoding: start.stderr, as: UTF8.self)
            throw DockerNetworkContainerPoolError.startFailed(name, stderr)
        }

        for _ in 0..<5 {
            if try await isHealthyWarmContainer(name, executor: executor) {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        throw DockerNetworkContainerPoolError.startFailed(name, "container not running after start")
    }

    private func isHealthyWarmContainer(_ name: String, executor: DockerCLIExecutor) async throws -> Bool {
        let running = try await executor(
            DockerScriptPreparer.dockerInspectContainerRunningArguments(containerName: name),
            Data(),
            15
        )
        return String(decoding: running.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }

    private func removeLegacyWarmContainers(executor: DockerCLIExecutor) async throws {
        for legacy in DockerScriptPreparer.legacyWarmContainerNames {
            _ = try? await executor(DockerScriptPreparer.dockerRmForceArguments(container: legacy), Data(), 15)
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
