import Foundation

public struct MessagingConnectorDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: String { pluginID }

    public let pluginID: String
    public var displayName: String
    public var listening: Bool
    public var unreadCount: Int
    public var listeningSince: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        pluginID: String,
        displayName: String,
        listening: Bool = false,
        unreadCount: Int = 0,
        listeningSince: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.pluginID = pluginID
        self.displayName = displayName
        self.listening = listening
        self.unreadCount = unreadCount
        self.listeningSince = listeningSince
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

/// Which messages to load for a conversation tab vs a nested Slack-style reply thread.
public enum MessagingMessageListFilter: Sendable, Hashable {
    /// Channel/DM feed: messages that are not replies.
    case channelRoots
    /// Root vendor message plus its replies (Slack `thread_ts`).
    case replyThread(parentVendorMessageID: String)
}

public struct MessagingMessageDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let threadID: String
    public var vendorMessageID: String?
    public let direction: MessagingMessageDirection
    public let sender: String
    public let body: String
    public let createdAt: Date
    /// Slack `thread_ts` when this row is a reply. Nil for channel-root messages.
    public var parentVendorMessageID: String?
    /// Vendor-reported reply count on a root message (Slack `reply_count`).
    public var replyCount: Int

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        vendorMessageID: String? = nil,
        direction: MessagingMessageDirection,
        sender: String,
        body: String,
        createdAt: Date = .now,
        parentVendorMessageID: String? = nil,
        replyCount: Int = 0
    ) {
        self.id = id
        self.threadID = threadID
        self.vendorMessageID = vendorMessageID
        self.direction = direction
        self.sender = sender
        self.body = body
        self.createdAt = createdAt
        self.parentVendorMessageID = Self.normalizedParentID(
            parentVendorMessageID,
            vendorMessageID: vendorMessageID
        )
        self.replyCount = max(0, replyCount)
    }

    public var isReply: Bool { parentVendorMessageID != nil }

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
    public let parentVendorMessageID: String?
    public let replyCount: Int

    public init(
        pluginID: String,
        vendorThreadID: String,
        threadTitle: String,
        vendorMessageID: String,
        sender: String,
        body: String,
        createdAt: Date = .now,
        countAsUnread: Bool = true,
        parentVendorMessageID: String? = nil,
        replyCount: Int = 0
    ) {
        self.pluginID = pluginID
        self.vendorThreadID = vendorThreadID
        self.threadTitle = threadTitle
        self.vendorMessageID = vendorMessageID
        self.sender = sender
        self.body = body
        self.createdAt = createdAt
        self.countAsUnread = countAsUnread
        self.parentVendorMessageID = MessagingMessageDTO.normalizedParentID(
            parentVendorMessageID,
            vendorMessageID: vendorMessageID
        )
        self.replyCount = max(0, replyCount)
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

extension MessagingMessageDTO {
    static func normalizedParentID(_ parent: String?, vendorMessageID: String?) -> String? {
        let trimmedParent = parent?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let trimmedVendor = vendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let trimmedParent else { return nil }
        if let trimmedVendor, trimmedParent == trimmedVendor { return nil }
        return trimmedParent
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
