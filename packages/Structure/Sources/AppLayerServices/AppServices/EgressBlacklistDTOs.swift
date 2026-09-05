import Foundation

/// Wire row for Settings ↔ daemon blacklist CRUD. Pattern is stored form (no `*.` prefix).
public struct EgressBlacklistEntryDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: String
    public var pattern: String
    public var displayPattern: String

    public init(id: String, kind: String, pattern: String, displayPattern: String) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.displayPattern = displayPattern
    }
}

public struct EgressBlacklistListResult: Codable, Sendable, Hashable {
    public var entries: [EgressBlacklistEntryDTO]

    public init(entries: [EgressBlacklistEntryDTO]) {
        self.entries = entries
    }
}

public struct EgressBlacklistAddRequest: Codable, Sendable, Hashable {
    public var pattern: String

    public init(pattern: String) {
        self.pattern = pattern
    }
}

public struct EgressBlacklistRemoveRequest: Codable, Sendable, Hashable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}
