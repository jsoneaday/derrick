import Foundation

/// Persisted chat session metadata for multi-session UI (Phase 2).
public struct ChatSessionDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: String { sessionID }

    public let applicationName: String
    public let sessionID: String
    public var title: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        applicationName: String,
        sessionID: String,
        title: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        metadata: [String: String] = [:]
    ) {
        self.applicationName = applicationName
        self.sessionID = sessionID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}
