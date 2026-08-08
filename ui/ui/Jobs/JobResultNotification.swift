import Foundation
import UserNotifications
import ServiceContracts

/// Post a user-visible notification for a completed job wake.
/// **Only safe from the main UI process** (`derrick.ui`). Calling from an XPC service
/// traps: `bundleProxyForCurrentProcess is nil`.
public enum JobResultNotificationPoster {
    public static let categoryID = "JOB_RESULT"
    public static let resultIDKey = "jobResultID"
    public static let jobIDKey = "jobID"

    /// True only for the host app — never XPC helpers.
    public static var isMainAppProcess: Bool {
        (Bundle.main.bundleIdentifier ?? "") == DerrickServiceID.ui.rawValue
    }

    /// Request alert permission (idempotent). Call once from the UI process at launch.
    public static func requestAuthorizationIfNeeded() {
        guard isMainAppProcess else {
            fputs("[JobResultNotification] skip auth (not main app: \(Bundle.main.bundleIdentifier ?? "?"))\n", stderr)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                fputs("[JobResultNotification] auth error: \(error.localizedDescription)\n", stderr)
            } else {
                fputs("[JobResultNotification] auth granted=\(granted)\n", stderr)
            }
        }
        let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    public static func post(result: JobResultDTO) {
        guard isMainAppProcess else {
            fputs("[JobResultNotification] skip post (not main app)\n", stderr)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Scheduled job finished"
        let preview = result.responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = preview.count > 180 ? String(preview.prefix(177)) + "…" : (preview.isEmpty ? "Tap to view result" : preview)
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = [
            resultIDKey: result.id,
            jobIDKey: result.jobID
        ]

        let request = UNNotificationRequest(
            identifier: "job-result-\(result.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                fputs("[JobResultNotification] post failed: \(error.localizedDescription)\n", stderr)
            } else {
                fputs("[JobResultNotification] posted id=\(result.id) job=\(result.jobID)\n", stderr)
            }
        }
    }
}
