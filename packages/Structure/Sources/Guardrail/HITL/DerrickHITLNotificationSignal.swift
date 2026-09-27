import Foundation

/// Cross-process nudge so derrickd polls SQLite for pending HITL approvals immediately.
public enum DerrickHITLNotificationSignal: Sendable {
    public static let darwinName = "derrickd.pollHITLApprovals"

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
