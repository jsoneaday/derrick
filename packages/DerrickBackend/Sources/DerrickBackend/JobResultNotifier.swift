import AppKit
import DBRepository
import Foundation
import ServiceContracts

/// Persisted job result → Daemon UserNotifications (sole poster).
public enum JobResultNotifier: Sendable {
    /// Claim DB row and ask the Daemon to post. Safe to call from AgentService / JobService.
    /// When `liveUIModal` is true the interactive UI is already showing the result panel — skip notification + wake.
    public static func notifyCompletion(
        resultID: String,
        jobID: String,
        responseText: String,
        repository: DBRepository,
        liveUIModal: Bool = false
    ) async {
        if liveUIModal {
            fputs("[JobResultNotifier] skip notification (live UI modal) id=\(resultID)\n", stderr)
            return
        }

        guard DerrickUIPresence.isInteractiveUIRunning() == false else {
            fputs(
                "[JobResultNotifier] skip notification (derrick.ui running; live modal path) id=\(resultID)\n",
                stderr
            )
            return
        }

        do {
            let claimed = try await repository.claimJobResultNotificationPost(id: resultID)
            guard claimed else {
                fputs("[JobResultNotifier] skip already claimed id=\(resultID)\n", stderr)
                return
            }
        } catch {
            fputs("[JobResultNotifier] claim failed id=\(resultID): \(error.localizedDescription)\n", stderr)
            return
        }

        let shortID = String(resultID.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
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

        // Keep UI tap routing keys stable (`DerrickNotificationPayload` / UserNotificationPoster).
        let request = UserNotificationRequest(
            id: "derrick.job-result.\(resultID)",
            kind: .jobResult,
            title: "Derrick · Job finished",
            body: body.isEmpty ? "Job finished." : body,
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
        } catch {
            try? await repository.resetJobResultNotificationClaim(id: resultID)
            fputs(
                "[JobResultNotifier] daemon post failed id=\(resultID): \(error.localizedDescription)\n",
                stderr
            )
        }
        // Modal is shown only when the user taps the notification (DaemonNotificationCenterDelegate).
    }
}
