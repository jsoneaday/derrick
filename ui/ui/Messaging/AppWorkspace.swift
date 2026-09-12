import Foundation

enum AppWorkspace: Equatable {
    case chats
    case debugLogs
}

enum ChatShellNotification {
    static let startPluginCreation = Notification.Name("derrick.startPluginCreation")
    static let openPluginInChat = Notification.Name("derrick.openPluginInChat")
    static let pluginIDUserInfoKey = "pluginID"
}
