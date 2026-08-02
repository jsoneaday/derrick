import Foundation
import AgentRuntime
import MemorySystem

/// Session-scoped multi-agent entry point (MA-1/MA-2).
final class SessionOrchestrator: Sendable {
    let sessionID: String
    let directory: InMemoryAgentDirectory
    let hierarchy: HierarchicalOrchestrator
    let limits: OrchestrationLimits
    let userFacingRef: AgentRef

    /// Turn context for worker LLM runs (set per user turn).
    private let turnContext: TurnContextStore

    init(
        sessionID: String,
        directory: InMemoryAgentDirectory = InMemoryAgentDirectory(),
        limits: OrchestrationLimits = .recommended
    ) {
        self.sessionID = sessionID
        self.directory = directory
        self.hierarchy = HierarchicalOrchestrator(directory: directory)
        self.limits = limits
        self.userFacingRef = AgentRef.userFacing(sessionID: sessionID)
        self.turnContext = TurnContextStore()
    }

    func bootstrapUserFacingAgent() async throws {
        let record = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        assert(record.ref == userFacingRef)
        debugLog("AgentRuntime: ensured user-facing agent \(record.ref.agentID) session=\(sessionID)")
    }

    var memorySessionKey: MemorySessionKey {
        MemorySessionKey(sessionID: userFacingRef.sessionID, agentID: userFacingRef.agentID)
    }

    /// Installs the worker turn runner for the duration of a user-facing turn.
    func withWorkerRunner<T: Sendable>(
        _ runner: @escaping @Sendable (_ child: AgentRecord, _ envelope: AgentEnvelope) async throws -> String,
        operation: () async throws -> T
    ) async rethrows -> T {
        await turnContext.setRunner(runner)
        defer { Task { await turnContext.setRunner(nil) } }
        return try await operation()
    }

    func deliverUserMessage(
        _ prompt: String,
        correlationId: String? = nil,
        execute: @escaping @Sendable (AgentEnvelope) async throws -> Void
    ) async throws {
        let envelope = AgentEnvelope.userMessage(
            to: userFacingRef,
            body: prompt,
            correlationId: correlationId
        )
        try await directory.deliver(envelope, execute: execute)
    }

    // MARK: - Tool surface (called from MCP handlers)

    func spawnWorker(goal: String, task: String, agentID: String?) async throws -> String {
        guard let runner = await turnContext.runner else {
            throw AgentRuntimeError.turnInProgress(userFacingRef)
        }
        // Caller identity: for MA-2, only user-facing spawns from the chat path.
        let caller = await turnContext.callerAgent ?? userFacingRef
        let outcome = try await hierarchy.spawnAndAwait(
            SpawnWorkerRequest(parent: caller, goal: goal, task: task, agentID: agentID),
            runTurn: runner
        )
        debugLog(
            "AgentRuntime: spawn \(outcome.child.agentID) status=\(outcome.status.rawValue) resultChars=\(outcome.result.count)"
        )
        return """
        child_agent_id: \(outcome.child.agentID)
        status: \(outcome.status.rawValue)
        result:
        \(outcome.result)
        """
    }

    func completeTask(result: String) async throws -> String {
        let worker = await turnContext.callerAgent ?? userFacingRef
        try await hierarchy.completeTask(worker: worker, result: result)
        return "task completed for \(worker.agentID)"
    }

    func listAgents(childrenOnly: Bool) async throws -> String {
        let caller = await turnContext.callerAgent ?? userFacingRef
        let records: [AgentRecord]
        if childrenOnly {
            records = await hierarchy.listChildren(of: caller)
        } else {
            records = await hierarchy.listAgents(sessionID: sessionID)
        }
        if records.isEmpty { return "[]" }
        return records.map { r in
            let parent = r.parentAgentID ?? "-"
            return "- \(r.ref.agentID) role=\(r.role.rawValue) status=\(r.status.rawValue) parent=\(parent) goal=\(r.goal ?? "")"
        }.joined(separator: "\n")
    }

    func send(toAgentID: String, message: String) async throws -> String {
        let from = await turnContext.callerAgent ?? userFacingRef
        try await hierarchy.send(from: from, toAgentID: toAgentID, message: message)
        return "message queued to \(toAgentID)"
    }

    func cancel(agentID: String) async throws -> String {
        let requester = await turnContext.callerAgent ?? userFacingRef
        let target = AgentRef(sessionID: sessionID, agentID: agentID)
        try await hierarchy.cancel(agent: target, by: requester)
        return "cancelled \(agentID)"
    }

    func setCallerAgent(_ ref: AgentRef?) async {
        await turnContext.setCaller(ref)
    }
}

// MARK: - Turn context

private actor TurnContextStore {
    private(set) var runner: (@Sendable (AgentRecord, AgentEnvelope) async throws -> String)?
    private(set) var callerAgent: AgentRef?

    func setRunner(_ runner: (@Sendable (AgentRecord, AgentEnvelope) async throws -> String)?) {
        self.runner = runner
    }

    func setCaller(_ ref: AgentRef?) {
        callerAgent = ref
    }
}

extension MemorySessionKey {
    init(agentRef: AgentRef) {
        self.init(sessionID: agentRef.sessionID, agentID: agentRef.agentID)
    }

    var agentRef: AgentRef {
        AgentRef(sessionID: sessionID, agentID: agentID)
    }
}
