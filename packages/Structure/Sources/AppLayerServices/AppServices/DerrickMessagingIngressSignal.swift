import Foundation

/// Wakes `MessagingIngressService` in derrickd to poll connector inboxes immediately.
public enum DerrickMessagingIngressSignal: Sendable {
    public static let darwinName = "derrickd.pollMessagingIngress"

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

/// Wakes the UI to reload messaging state after derrickd persisted inbound rows.
public enum DerrickMessagingInboundSignal: Sendable {
    public static let darwinName = "derrick.ui.messagingInbound"

    public static func postRefresh() {
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
