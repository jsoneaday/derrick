import Foundation

/// Egress / network host allow request (AgentService → UI).
public struct AgentNetworkAccessRequestDTO: Codable, Sendable, Hashable {
    public let requestID: String
    public let host: String
    public let toolName: String

    public init(
        requestID: String = UUID().uuidString,
        host: String,
        toolName: String = "script_exec"
    ) {
        self.requestID = requestID
        self.host = host
        self.toolName = toolName
    }
}

/// UI decision for network host access.
/// `decision`: once | always | deny | dismissed | timeout
public struct AgentNetworkAccessDecisionDTO: Codable, Sendable, Hashable {
    public let requestID: String
    public let decision: String
    public let actor: String

    public init(requestID: String, decision: String, actor: String = "") {
        self.requestID = requestID
        self.decision = decision
        self.actor = actor
    }
}
