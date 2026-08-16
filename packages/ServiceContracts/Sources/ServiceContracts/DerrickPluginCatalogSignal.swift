import Foundation

/// Cross-process nudge so the UI reloads the installed-plugin sidebar.
public enum DerrickPluginCatalogSignal: Sendable {
    public static let darwinName = "derrick.plugins.changed"
    public static let localName = Notification.Name("derrick.plugins.changed")

    public static func post() {
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
