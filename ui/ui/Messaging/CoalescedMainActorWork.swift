import Foundation

/// Runs MainActor work one pass at a time. A call during a pass schedules one more pass.
@MainActor
final class CoalescedMainActorWork {
    private var task: Task<Void, Never>?
    private var generation = 0

    func schedule(_ work: @escaping @MainActor () async -> Void) {
        generation += 1
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let seen = self.generation
                await work()
                if self.generation == seen { break }
            }
            self.task = nil
        }
    }
}
