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
    /// `agents_complete_task` with no agent_id and no active worker turn.
    case completeTaskNoActiveWorker
    /// Concurrent workers; caller must pass `agent_id`.
    case completeTaskAmbiguousWorkers(agentIDs: [String])
}

extension AgentRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .agentNotFound(let ref):
            return "Agent not found: \(ref.agentID) (session \(ref.sessionID))."
        case .agentAlreadyExists(let ref):
            return "Agent already exists: \(ref.agentID)."
        case .sessionAgentLimitReached(let limit):
            return "Session agent limit reached (max \(limit))."
        case .childLimitReached(let parent, let limit):
            return "Child limit reached for \(parent.agentID) (max \(limit))."
        case .depthLimitReached(let limit):
            return "Agent hierarchy depth limit reached (max \(limit))."
        case .concurrentTurnLimitReached(let limit):
            return "Concurrent turn limit reached (max \(limit))."
        case .mailboxFull(let ref, let limit):
            return "Mailbox full for \(ref.agentID) (max \(limit))."
        case .spawnNotAllowed(let role):
            return "Role '\(role.rawValue)' is not allowed to perform this agent operation."
        case .invalidParent(let ref):
            return "Invalid parent agent: \(ref.agentID)."
        case .turnInProgress(let ref):
            return "A turn is already in progress for \(ref.agentID)."
        case .agentCancelled(let ref):
            return "Agent cancelled: \(ref.agentID)."
        case .notRelatedAgents(let from, let to):
            return "Agents \(from.agentID) and \(to.agentID) are not parent/child; peer messaging is not allowed."
        case .completeTaskNoActiveWorker:
            return "No active worker turn for agents_complete_task. Pass agent_id, or call only while a worker is running."
        case .completeTaskAmbiguousWorkers(let ids):
            return "Multiple active workers \(ids.joined(separator: ", ")); pass agent_id to agents_complete_task."
        }
    }
}
