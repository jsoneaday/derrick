import Foundation

/// Cross-process nudge so a running UI polls SQLite immediately after AgentService writes.
public enum DerrickNotificationSignal: Sendable {
    public static let darwinName = "derrick.ui.pollNotifications"

    public static func postPoll() {
        let name = CFNotificationName(darwinName as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }
}
