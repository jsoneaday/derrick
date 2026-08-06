import Foundation

/// Polls for due jobs and runs them via `JobServiceExecutor`.
final class JobServiceScheduler: @unchecked Sendable {
    static let shared = JobServiceScheduler()

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "derrick.ui.JobService.scheduler")

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 2.0)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        timer = t
        fputs("[JobService] scheduler started\n", stderr)
    }

    private func tick() {
        Task {
            do {
                let repo = try await JobServiceStore.shared.sharedRepository()
                let claimed = try await repo.claimDueJobs(limit: 5)
                for (job, steps) in claimed {
                    fputs("[JobService] claimed job id=\(job.id) steps=\(steps.count)\n", stderr)
                    await JobServiceExecutor.shared.execute(job: job, steps: steps)
                }
            } catch {
                fputs("[JobService] scheduler tick failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
