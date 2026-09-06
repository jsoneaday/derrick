import Foundation
import Structure

/// Shared permit queue for oneshot Docker work. Does not keep live containers.
///
/// Each kind of work (guest, crawler, extractor) has its own queue and cap.
/// Releasing the permit is the host "I'm done" signal so the next waiter can
/// `docker create` immediately.
public actor DerrickDockerRunQueue {
    public static let guest = DerrickDockerRunQueue(
        maxConcurrentContainers: ContainerLifecyclePolicy.derrickDefault.maxOfflineContainers
    )
    public static let crawler = DerrickDockerRunQueue(
        maxConcurrentContainers: ContainerLifecyclePolicy.derrickDefault.maxNetworkContainers
    )
    public static let extractor = DerrickDockerRunQueue(
        maxConcurrentContainers: ContainerLifecyclePolicy.derrickDefault.maxFileExtractContainers
    )

    nonisolated public let maxConcurrentContainers: Int
    private var activeContainers = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrentContainers: Int) {
        self.maxConcurrentContainers = max(1, maxConcurrentContainers)
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
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}
