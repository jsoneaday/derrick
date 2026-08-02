import Foundation

/// Addressable agent identity within a session/workspace.
/// Shape matches `MemorySessionKey` so memory/policy keep working without a package dependency.
public struct AgentRef: Hashable, Codable, Sendable {
    public let sessionID: String
    public let agentID: String

    public init(sessionID: String, agentID: String) {
        self.sessionID = sessionID
        self.agentID = agentID
    }

    /// Default user-facing agent id for interactive chat (parity with today's hard-coded `"ui"`).
    public static let userFacingAgentID = "ui"

    public static func userFacing(sessionID: String) -> AgentRef {
        AgentRef(sessionID: sessionID, agentID: userFacingAgentID)
    }
}
