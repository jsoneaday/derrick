import Foundation

/// Host-owned secret material. Never placed on the guest event.
public struct PluginSecretRecord: Codable, Sendable, Equatable {
    public var provider: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(provider: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.provider = provider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
