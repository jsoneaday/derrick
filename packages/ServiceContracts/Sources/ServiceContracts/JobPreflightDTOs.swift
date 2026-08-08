import Foundation

public struct JobPreflightItemDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// `tool` or `network`
    public let kind: String
    public let title: String
    public let detail: String

    public init(id: String = UUID().uuidString, kind: String, title: String, detail: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct JobPreflightRequestDTO: Codable, Sendable, Hashable {
    public let requestID: String
    public let toolName: String
    public let items: [JobPreflightItemDTO]

    public init(requestID: String = UUID().uuidString, toolName: String, items: [JobPreflightItemDTO]) {
        self.requestID = requestID
        self.toolName = toolName
        self.items = items
    }
}

public struct JobPreflightDecisionDTO: Codable, Sendable, Hashable {
    public let requestID: String
    public let approved: Bool
    /// Hosts approved for this session only.
    public let grantNetworkOnce: [String]
    /// Hosts approved permanently (suffix saved).
    public let grantNetworkAlways: [String]
    public let actor: String

    public init(
        requestID: String,
        approved: Bool,
        grantNetworkOnce: [String] = [],
        grantNetworkAlways: [String] = [],
        actor: String = ""
    ) {
        self.requestID = requestID
        self.approved = approved
        self.grantNetworkOnce = grantNetworkOnce
        self.grantNetworkAlways = grantNetworkAlways
        self.actor = actor
    }
}
