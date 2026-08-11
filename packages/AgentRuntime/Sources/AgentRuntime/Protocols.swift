import Foundation
import ServiceContracts

/// FIFO mailbox for a single agent.
public protocol AgentMailboxing: Sendable {
    func enqueue(_ envelope: AgentEnvelope) async throws
    func dequeue() async -> AgentEnvelope?
    func peekCount() async -> Int
}

/// Registry of agents for a session (or process).
public protocol AgentDirectorying: Sendable {
    var limits: OrchestrationLimits { get async }

    func record(for ref: AgentRef) async -> AgentRecord?
    func allRecords(sessionID: String) async -> [AgentRecord]

    /// Register a new agent. Enforces session agent cap and parent/child/depth rules when parent is set.
    @discardableResult
    func register(_ record: AgentRecord) async throws -> AgentRecord

    func updateStatus(_ ref: AgentRef, status: AgentStatus) async throws

    /// Ensures the default user-facing agent exists for a session.
    @discardableResult
    func ensureUserFacingAgent(sessionID: String) async throws -> AgentRecord

    /// Enqueue without starting a turn (parent mid-tool-call).
    func enqueueOnly(_ envelope: AgentEnvelope) async throws

    /// Enqueue envelope for `envelope.to` and process turns serially for that agent.
    /// `execute` runs one turn; directory enforces one active turn per agent and global concurrent turn cap.
    func deliver(
        _ envelope: AgentEnvelope,
        execute: nonisolated(nonsending) @escaping @Sendable (AgentEnvelope) async throws -> Void
    ) async throws
}

/// Executes one pipeline turn for an envelope (implemented in app layer over ConversationPipeline).
public protocol TurnRunning: Sendable {
    func run(envelope: AgentEnvelope) async throws
}
