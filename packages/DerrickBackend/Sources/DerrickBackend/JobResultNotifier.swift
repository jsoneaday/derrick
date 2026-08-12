import DBRepository
import Foundation
import ServiceContracts

/// Persisted job result → Daemon UserNotifications (sole poster).
///
/// Modal presentation is **only** via notification tap (`DaemonNotificationCenterDelegate` → `DaemonUILauncher`).
public enum JobResultNotifier: Sendable {
    /// Claim DB row and ask the Daemon to post. Safe to call from AgentService / JobService.
    /// Returns `true` only when a notification was handed to the system poster.
    @discardableResult
    public static func notifyCompletion(
        resultID: String,
        jobID: String,
        responseText: String,
        repository: DBRepository
    ) async -> Bool {
        do {
            let claimed = try await repository.claimJobResultNotificationPost(id: resultID)
            guard claimed else {
                fputs("[JobResultNotifier] skip already claimed id=\(resultID)\n", stderr)
                return false
            }
        } catch {
            fputs("[JobResultNotifier] claim failed id=\(resultID): \(error.localizedDescription)\n", stderr)
            return false
        }

        let shortID = String(resultID.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
        let jobFailed = (try? await repository.fetchJobStatus(id: jobID)) == JobStatus.failed.rawValue
        let title = jobFailed ? "Derrick · Job failed" : "Derrick · Job finished"
        var scheduled = ""
        if let runAt = try? await repository.fetchJobRunAt(jobID: jobID) {
            scheduled = "Scheduled for \(runAt.formatted(date: .abbreviated, time: .shortened)). "
        }
        let bodyLimit = 220
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = trimmed.count > bodyLimit
            ? String(trimmed.prefix(bodyLimit - 1)) + "…"
            : trimmed
        let body = scheduled + truncated

        let request = UserNotificationRequest(
            id: "derrick.job-result.\(resultID)",
            kind: .jobResult,
            title: title,
            body: body.isEmpty ? (jobFailed ? "Job failed." : "Job finished.") : body,
            subtitle: "Result \(shortID)",
            threadIdentifier: "derrick.job-result.\(resultID)",
            timeSensitive: true,
            userInfo: [
                UserNotificationUserInfoKey.kind.rawValue: UserNotificationKind.jobResult.rawValue,
                UserNotificationUserInfoKey.jobResultID.rawValue: resultID
            ]
        )

        do {
            try await NotificationSender.post(request)
            fputs("[JobResultNotifier] posted via daemon id=\(resultID)\n", stderr)
            return true
        } catch {
            try? await repository.resetJobResultNotificationClaim(id: resultID)
            fputs(
                "[JobResultNotifier] daemon post failed id=\(resultID): \(error.localizedDescription)\n",
                stderr
            )
            return false
        }
    }
}
