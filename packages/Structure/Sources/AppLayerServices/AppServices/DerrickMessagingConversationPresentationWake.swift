import Foundation

/// Cross-process wake to open a connector conversation (sandbox-safe: app group file + Darwin notify).
public enum DerrickMessagingConversationPresentationWake: Sendable {
    public static let darwinName = "derrick.ui.presentMessagingConversation"
    public static let localNotificationName = Notification.Name("derrick.ui.presentMessagingConversation.local")
    public static let uiOpenNotificationName = Notification.Name("derrick.openMessagingConversation")
    public static let pluginIDUserInfoKey = UserNotificationUserInfoKey.pluginID.rawValue
    public static let threadIDUserInfoKey = UserNotificationUserInfoKey.threadID.rawValue
    private static let pendingFileName = "pending_messaging_conversation_presentation.json"

    public struct Payload: Codable, Sendable, Equatable {
        public let pluginID: String
        public let threadID: String

        public init(pluginID: String, threadID: String) {
            self.pluginID = pluginID
            self.threadID = threadID
        }

        public var isValid: Bool {
            !pluginID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func post(pluginID: String, threadID: String) {
        post(Payload(pluginID: pluginID, threadID: threadID))
    }

    public static func post(_ payload: Payload) {
        guard payload.isValid else { return }
        if let url = pendingFileURL(),
           let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
        let name = CFNotificationName(darwinName as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }

    public static func peekPending() -> Payload? {
        readPending()
    }

    public static func takePending() -> Payload? {
        guard let payload = readPending(), let url = pendingFileURL() else { return nil }
        try? FileManager.default.removeItem(at: url)
        return payload
    }

    public static func requestOpenInUI(_ payload: Payload) {
        guard payload.isValid else { return }
        NotificationCenter.default.post(
            name: uiOpenNotificationName,
            object: nil,
            userInfo: [
                pluginIDUserInfoKey: payload.pluginID,
                threadIDUserInfoKey: payload.threadID,
            ]
        )
    }

    private static func readPending() -> Payload? {
        guard let url = pendingFileURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.isValid
        else {
            return nil
        }
        return payload
    }

    private static func pendingFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier)?
            .appendingPathComponent(pendingFileName, isDirectory: false)
    }
}
