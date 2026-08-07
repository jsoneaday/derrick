import Foundation
import ServiceContracts

/// Polls due **schedules** (spawn job runs) and due **jobs** (execute steps).
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
        fputs("[JobService] scheduler started (schedules + job runs)\n", stderr)
        // One-shot recovery for jobs left mid-flight after sleep/crash/logout.
        Task { await reapInterruptedJobs() }
    }

    private func tick() {
        Task {
            await fireDueSchedules()
            await runDueJobs()
        }
    }

    /// Jobs stuck in `running` when JobService died → clear failure reason.
    private func reapInterruptedJobs() async {
        do {
            let repo = try await JobServiceStore.shared.sharedRepository()
            let reason = JobFailureReason.interruptedDeviceUnavailable
            let count = try await repo.failInterruptedRunningJobs(
                errorMessage: reason.lastAttemptMessage(),
                errorCode: reason.rawValue
            )
            if count > 0 {
                fputs("[JobService] reaped \(count) interrupted running job(s)\n", stderr)
                await JobServiceStore.shared.log(
                    level: .warning,
                    message: "reaped \(count) interrupted running job(s)",
                    code: "job_reap_interrupted"
                )
            }
        } catch {
            fputs("[JobService] reap interrupted failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Enabled schedules with nextFireAt <= now → create job run, advance recurrence.
    private func fireDueSchedules() async {
        do {
            let repo = try await JobServiceStore.shared.sharedRepository()
            let claimed = try await repo.claimDueSchedules(limit: 10, now: Date()) { row, firedAt in
                let recurrence = JobRecurrence(
                    kind: JobRecurrenceKind(rawValue: row.recurrenceKind) ?? .once,
                    intervalSeconds: row.intervalSeconds
                )
                if let next = JobScheduleTiming.nextFireDate(after: firedAt, recurrence: recurrence) {
                    return (enabled: true, nextFireAt: next)
                }
                // once: disable after fire
                return (enabled: false, nextFireAt: nil)
            }
            for schedule in claimed {
                do {
                    let job = try await JobServiceHost.shared.spawnJob(from: schedule)
                    fputs(
                        "[JobService] schedule fired id=\(schedule.id) name=\(schedule.name) → job=\(job.id)\n",
                        stderr
                    )
                    await JobServiceStore.shared.log(
                        level: .info,
                        message: "schedule fired id=\(schedule.id) job=\(job.id)",
                        code: "schedule_fire"
                    )
                } catch {
                    fputs(
                        "[JobService] schedule spawn failed id=\(schedule.id): \(error.localizedDescription)\n",
                        stderr
                    )
                }
            }
        } catch {
            fputs("[JobService] schedule tick failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func runDueJobs() async {
        do {
            let repo = try await JobServiceStore.shared.sharedRepository()
            let claimed = try await repo.claimDueJobs(limit: 5)
            let now = Date()
            for (job, steps) in claimed {
                // Catch-up after sleep / offline: note lateness; do not fail the job for that alone.
                if let runAt = job.runAt, now.timeIntervalSince(runAt) > 60 {
                    let detail = JobStatusDetail.startedLate(scheduledAt: runAt, startedAt: now)
                    try? await repo.updateJobStatusDetail(id: job.id, statusDetail: detail)
                    fputs("[JobService] job id=\(job.id) \(detail)\n", stderr)
                    await JobServiceStore.shared.log(
                        level: .info,
                        message: "job id=\(job.id) \(detail)",
                        code: "job_started_late"
                    )
                }
                fputs("[JobService] claimed job id=\(job.id) steps=\(steps.count)\n", stderr)
                await JobServiceExecutor.shared.execute(job: job, steps: steps)
            }
        } catch {
            fputs("[JobService] job tick failed: \(error.localizedDescription)\n", stderr)
        }
    }
}
