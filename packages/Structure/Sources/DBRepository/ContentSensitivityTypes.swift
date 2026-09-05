import Foundation

/// Permanent or session grant that skips content-confirm for a sensitivity category.
public struct ContentSensitivityGrant: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    /// Stable id: `email`, `phone`, `ssn`, …
    public var category: String
    /// `permanent` | `session`
    public var scope: String
    public var sessionID: String?
    public var actor: String?
    public var enabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        category: String,
        scope: String,
        sessionID: String? = nil,
        actor: String? = nil,
        enabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.category = category
        self.scope = scope
        self.sessionID = sessionID
        self.actor = actor
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
