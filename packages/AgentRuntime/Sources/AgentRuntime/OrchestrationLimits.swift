import Foundation

/// Hard caps for multi-agent orchestration (recommended defaults).
public struct OrchestrationLimits: Hashable, Codable, Sendable {
    /// Max parent→child depth (user_facing = 0). Recommended: 2.
    public var maxDepth: Int
    /// Max direct children per agent. Recommended: 4.
    public var maxChildrenPerAgent: Int
    /// Max concurrent turns across all agents in a session. Recommended: 4.
    public var maxConcurrentTurns: Int
    /// Max agents registered in a session. Recommended: 8.
    public var maxAgentsPerSession: Int
    /// Max pending envelopes per agent mailbox.
    public var maxMailboxDepth: Int

    public init(
        maxDepth: Int = 2,
        maxChildrenPerAgent: Int = 4,
        maxConcurrentTurns: Int = 4,
        maxAgentsPerSession: Int = 8,
        maxMailboxDepth: Int = 64
    ) {
        self.maxDepth = maxDepth
        self.maxChildrenPerAgent = maxChildrenPerAgent
        self.maxConcurrentTurns = maxConcurrentTurns
        self.maxAgentsPerSession = maxAgentsPerSession
        self.maxMailboxDepth = maxMailboxDepth
    }

    public static let recommended = OrchestrationLimits()
}
