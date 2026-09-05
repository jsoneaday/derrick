import Foundation

/// One permanently stored domain suffix allowed by the egress proxy.
public struct EgressAllowedDomainSuffix: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var suffix: String
    /// `seed` | `user`
    public var source: String
    public var enabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        suffix: String,
        source: String,
        enabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.suffix = suffix
        self.source = source
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
