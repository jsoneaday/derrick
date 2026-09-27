import Foundation

/// FIFO mailbox for a single agent.
public protocol AgentMailboxing: Sendable {
    func enqueue(_ envelope: AgentEnvelope) async throws
    func dequeue() async -> AgentEnvelope?
    func peekCount() async -> Int
}

/// Authoritative registry of runtime agent instances for a session or process.
///
/// This is the Phase 1 name for the existing registry contract. Message
/// delivery remains here temporarily for source compatibility; the
/// AgentOrchestrationModule will separate registry and directing concerns.
public protocol AgentRegistryManaging: Sendable {
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

/// Directs runtime agents through delegation, messaging, completion, and
/// cancellation operations.
public protocol AgentDirecting: Sendable {
    func spawnAndAwait(
        _ request: SpawnWorkerRequest,
        runTurn: @escaping @Sendable (_ child: AgentRecord, _ envelope: AgentEnvelope) async throws -> String
    ) async throws -> SpawnWorkerResult

    func spawnManyAndAwait(
        _ requests: [SpawnWorkerRequest],
        runTurn: @escaping @Sendable (_ child: AgentRecord, _ envelope: AgentEnvelope) async throws -> String
    ) async throws -> [SpawnWorkerResult]

    func completeTask(worker: AgentRef, result: String) async throws
    func listAgents(sessionID: String) async -> [AgentRecord]
    func listChildren(of parent: AgentRef) async -> [AgentRecord]
    func send(from: AgentRef, toAgentID: String, message: String) async throws
    func cancel(agent: AgentRef, by requester: AgentRef) async throws
}

/// Composite facade implemented by the future AgentOrchestrationModule.
public protocol AgentOrchestrationServing: AgentRegistryManaging, AgentDirecting {}
