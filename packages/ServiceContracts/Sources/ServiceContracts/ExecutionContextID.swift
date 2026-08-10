import Foundation

/// Stable identity for an agent execution context (session + agent).
/// Used by turn queues, HITL routing, and container leases.
public struct ExecutionContextID: Hashable, Codable, Sendable {
    public let sessionID: String
    public let agentID: String

    public init(sessionID: String, agentID: String) {
        self.sessionID = sessionID
        self.agentID = agentID
    }
}
