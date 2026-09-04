import Foundation

public extension Notification.Name {
    static let derrickOpenMessagingConnector = Notification.Name("derrick.openMessagingConnector")
}

public enum PluginFactoryTurnNavigation {
    public static let pluginIDUserInfoKey = "pluginID"

    public static func requestOpenMessagingConnector(pluginID: String) {
        NotificationCenter.default.post(
            name: .derrickOpenMessagingConnector,
            object: nil,
            userInfo: [pluginIDUserInfoKey: pluginID]
        )
    }
}
