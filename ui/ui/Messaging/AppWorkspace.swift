import Foundation

enum AppWorkspace: Equatable {
    case chats
    /// New or focused plugin-creator Q&A.
    case pluginsCreate
    /// Installed Agent Plugin package browser.
    case pluginsList
    case debugLogs

    var isPluginsSection: Bool {
        switch self {
        case .pluginsCreate, .pluginsList:
            return true
        case .chats, .debugLogs:
            return false
        }
    }
}

enum ChatShellNotification {
    static let startPluginCreation = Notification.Name("derrick.startPluginCreation")
    static let startPluginEdit = Notification.Name("derrick.startPluginEdit")
    static let openPluginInChat = Notification.Name("derrick.openPluginInChat")
    static let openPluginList = Notification.Name("derrick.openPluginList")
    static let pluginFactorySucceeded = Notification.Name("derrick.pluginFactorySucceeded")
    /// Posted when a plugin (all versions) is removed so Chat can drop its tabs.
    static let pluginDeleted = Notification.Name("derrick.pluginDeleted")
    static let pluginIDUserInfoKey = "pluginID"
    static let pluginVersionUserInfoKey = "pluginVersion"
    static let editPromptUserInfoKey = "editPrompt"
}
