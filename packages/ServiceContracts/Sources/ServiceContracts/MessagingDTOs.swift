import Foundation

public struct MessagingConnectorDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: String { pluginID }

    public let pluginID: String
    public var displayName: String
    public var listening: Bool
    public var unreadCount: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        pluginID: String,
        displayName: String,
        listening: Bool = false,
        unreadCount: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.pluginID = pluginID
        self.displayName = displayName
        self.listening = listening
        self.unreadCount = unreadCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MessagingThreadDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let pluginID: String
    public let vendorThreadID: String
    public var title: String
    public var lastActivityAt: Date
    public var muted: Bool
    public var unreadCount: Int
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        pluginID: String,
        vendorThreadID: String,
        title: String,
        lastActivityAt: Date = .now,
        muted: Bool = false,
        unreadCount: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.pluginID = pluginID
        self.vendorThreadID = vendorThreadID
        self.title = title
        self.lastActivityAt = lastActivityAt
        self.muted = muted
        self.unreadCount = unreadCount
        self.createdAt = createdAt
    }
}

public enum MessagingMessageDirection: String, Codable, Sendable, Hashable {
    case inbound
    case outbound
}

public struct MessagingMessageDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let threadID: String
    public var vendorMessageID: String?
    public let direction: MessagingMessageDirection
    public let sender: String
    public let body: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        vendorMessageID: String? = nil,
        direction: MessagingMessageDirection,
        sender: String,
        body: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.threadID = threadID
        self.vendorMessageID = vendorMessageID
        self.direction = direction
        self.sender = sender
        self.body = body
        self.createdAt = createdAt
    }

    public var cursor: MessagingMessageCursor {
        MessagingMessageCursor(createdAt: createdAt, id: id)
    }
}

/// Stable older-page cursor. Time alone is not unique on reconnect bursts.
public struct MessagingMessageCursor: Sendable, Hashable {
    public let createdAt: Date
    public let id: String

    public init(createdAt: Date, id: String) {
        self.createdAt = createdAt
        self.id = id
    }
}

/// One inbound vendor message. Persist is idempotent on `(pluginID, vendorThreadID, vendorMessageID)`.
public struct MessagingInboundRecord: Sendable, Hashable {
    public let pluginID: String
    public let vendorThreadID: String
    public let threadTitle: String
    public let vendorMessageID: String
    public let sender: String
    public let body: String
    public let createdAt: Date
    public let countAsUnread: Bool

    public init(
        pluginID: String,
        vendorThreadID: String,
        threadTitle: String,
        vendorMessageID: String,
        sender: String,
        body: String,
        createdAt: Date = .now,
        countAsUnread: Bool = true
    ) {
        self.pluginID = pluginID
        self.vendorThreadID = vendorThreadID
        self.threadTitle = threadTitle
        self.vendorMessageID = vendorMessageID
        self.sender = sender
        self.body = body
        self.createdAt = createdAt
        self.countAsUnread = countAsUnread
    }
}

public struct MessagingPersistResult: Sendable, Hashable {
    public let inserted: Bool
    public let message: MessagingMessageDTO
    public let thread: MessagingThreadDTO

    public init(inserted: Bool, message: MessagingMessageDTO, thread: MessagingThreadDTO) {
        self.inserted = inserted
        self.message = message
        self.thread = thread
    }
}

public struct MessagingRoute: Sendable, Hashable {
    public var isMessagingWorkspace: Bool
    public var pluginID: String?
    public var threadID: String?

    public init(
        isMessagingWorkspace: Bool = false,
        pluginID: String? = nil,
        threadID: String? = nil
    ) {
        self.isMessagingWorkspace = isMessagingWorkspace
        self.pluginID = pluginID
        self.threadID = threadID
    }

    public func isViewing(pluginID: String, threadID: String) -> Bool {
        isMessagingWorkspace && self.pluginID == pluginID && self.threadID == threadID
    }
}

public enum MessagingViewport {
    public static let maxVisibleMessages = 100
}
