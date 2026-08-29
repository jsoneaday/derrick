import Foundation

/// Kind of user-visible notification (posted only by the Daemon process).
public enum UserNotificationKind: String, Codable, Sendable, Hashable {
    case jobResult
    case hitlApproval
    case notice
    case messagingMessage
}

/// Cross-process request to post a macOS user notification.
public struct UserNotificationRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: UserNotificationKind
    public var title: String
    public var body: String
    public var subtitle: String?
    public var threadIdentifier: String?
    public var timeSensitive: Bool
    /// Opaque payload for tap handling (job result id, approval id, …).
    public var userInfo: [String: String]

    public init(
        id: String = UUID().uuidString,
        kind: UserNotificationKind,
        title: String,
        body: String,
        subtitle: String? = nil,
        threadIdentifier: String? = nil,
        timeSensitive: Bool = false,
        userInfo: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.subtitle = subtitle
        self.threadIdentifier = threadIdentifier
        self.timeSensitive = timeSensitive
        self.userInfo = userInfo
    }
}

/// Well-known userInfo keys for notification tap routing.
public enum UserNotificationUserInfoKey: String, Sendable {
    case kind = "kind"
    case jobResultID = "jobResultID"
    case approvalID = "approvalID"
    case pluginID = "pluginID"
    case threadID = "threadID"
    case messagingMessageID = "messagingMessageID"
}
