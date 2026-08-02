import Foundation

public enum AgentRuntimeError: Error, Sendable, Equatable {
    case agentNotFound(AgentRef)
    case agentAlreadyExists(AgentRef)
    case sessionAgentLimitReached(limit: Int)
    case childLimitReached(parent: AgentRef, limit: Int)
    case depthLimitReached(limit: Int)
    case concurrentTurnLimitReached(limit: Int)
    case mailboxFull(AgentRef, limit: Int)
    case spawnNotAllowed(role: AgentRole)
    case invalidParent(AgentRef)
    case turnInProgress(AgentRef)
    case agentCancelled(AgentRef)
    case notRelatedAgents(from: AgentRef, to: AgentRef)
}
