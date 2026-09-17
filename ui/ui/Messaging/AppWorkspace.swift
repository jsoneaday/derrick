import Foundation

enum AppWorkspace: Equatable {
    case chats
    case plugins
    case debugLogs
}

enum ChatShellNotification {
    static let startPluginCreation = Notification.Name("derrick.startPluginCreation")
    static let startPluginEdit = Notification.Name("derrick.startPluginEdit")
    static let openPluginInChat = Notification.Name("derrick.openPluginInChat")
    static let pluginFactorySucceeded = Notification.Name("derrick.pluginFactorySucceeded")
    static let pluginIDUserInfoKey = "pluginID"
    static let pluginVersionUserInfoKey = "pluginVersion"
    static let editPromptUserInfoKey = "editPrompt"
}
