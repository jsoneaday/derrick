import Foundation
import DockerRunnerXPC
import Structure

/// Bounds concurrent Swift container work across factory and script execution.
public actor SwiftDockerContainerPool {
    public static let shared = SwiftDockerContainerPool()

    private let maxConcurrentContainers: Int
    private var activeContainers = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrentContainers: Int = 2) {
        self.maxConcurrentContainers = max(1, maxConcurrentContainers)
    }

    public func prewarm(
        image: String,
        executor: @escaping DockerCLIExecutor
    ) async throws {
        let inspect = try await executor(["image", "inspect", image], Data(), 30)
        guard inspect.exitCode != 0 else { return }
        let pulled = try await executor(["pull", image], Data(), 1_200)
        guard pulled.exitCode == 0 else {
            let detail = String(decoding: pulled.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SwiftDockerContainerPoolError.imageUnavailable(
                detail.isEmpty ? "exit \(pulled.exitCode)" : detail
            )
        }
    }

    public func withPermit<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        defer {
            release()
        }
        return try await operation()
    }

    private func acquire() async {
        while activeContainers >= maxConcurrentContainers {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        activeContainers += 1
    }

    private func release() {
        activeContainers = max(0, activeContainers - 1)
        let pending = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in pending {
            waiter.resume()
        }
    }
}

public enum SwiftDockerContainerPoolError: Error, LocalizedError, Equatable, Sendable {
    case imageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .imageUnavailable(let detail):
            return "Guest runtime image is unavailable: \(detail)"
        }
    }
}
