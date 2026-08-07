import Foundation
import IOKit.pwr_mgt

/// Holds a system idle-sleep assertion while one or more jobs are executing.
///
/// - Does **not** keep the Mac awake when idle (only while jobs run).
/// - Ref-counted so concurrent jobs share one assertion.
/// - Uses `PreventUserIdleSystemSleep` (display may still sleep; system stays up for work).
final class JobServiceSleepAssertion: @unchecked Sendable {
    static let shared = JobServiceSleepAssertion()

    private let lock = NSLock()
    private var retainCount = 0
    private var assertionID: IOPMAssertionID = 0
    private var processActivity: NSObjectProtocol?

    private init() {}

    /// Begin preventing idle system sleep for a job run. Always pair with `end(token:)`.
    func begin(jobID: String) -> Token {
        lock.lock()
        defer { lock.unlock() }
        retainCount += 1
        if retainCount == 1 {
            createAssertion(reason: "Derrick job running (\(jobID))")
        }
        fputs(
            "[JobService] sleep assertion begin job=\(jobID) retain=\(retainCount)\n",
            stderr
        )
        return Token(owner: self, jobID: jobID)
    }

    fileprivate func end(jobID: String) {
        lock.lock()
        defer { lock.unlock() }
        retainCount = max(0, retainCount - 1)
        fputs(
            "[JobService] sleep assertion end job=\(jobID) retain=\(retainCount)\n",
            stderr
        )
        if retainCount == 0 {
            releaseAssertion()
        }
    }

    private func createAssertion(reason: String) {
        // Prefer ProcessInfo activity (Swift-friendly) + IOPM for idle system sleep.
        processActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: reason
        )

        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if status == kIOReturnSuccess {
            assertionID = id
            fputs("[JobService] IOPM NoIdleSleep assertion id=\(id)\n", stderr)
        } else {
            assertionID = 0
            fputs(
                "[JobService] IOPM assertion create failed status=\(status) (ProcessInfo activity still held)\n",
                stderr
            )
        }
    }

    private func releaseAssertion() {
        if assertionID != 0 {
            let status = IOPMAssertionRelease(assertionID)
            fputs(
                "[JobService] IOPM assertion released id=\(assertionID) status=\(status)\n",
                stderr
            )
            assertionID = 0
        }
        if let activity = processActivity {
            ProcessInfo.processInfo.endActivity(activity)
            processActivity = nil
            fputs("[JobService] ProcessInfo activity ended\n", stderr)
        }
    }

    /// RAII-style token; ends assertion when deinitialized or `end()` is called.
    final class Token: @unchecked Sendable {
        private let owner: JobServiceSleepAssertion
        private let jobID: String
        private let lock = NSLock()
        private var ended = false

        fileprivate init(owner: JobServiceSleepAssertion, jobID: String) {
            self.owner = owner
            self.jobID = jobID
        }

        func end() {
            lock.lock()
            defer { lock.unlock() }
            guard !ended else { return }
            ended = true
            owner.end(jobID: jobID)
        }

        deinit {
            end()
        }
    }
}
