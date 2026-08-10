import Foundation
import AgentRuntime
import MemorySystem
import DBRepository

/// Session-scoped multi-agent entry point (MA-1–MA-3).
final class SessionOrchestrator: Sendable {
    let sessionID: String
    let directory: any AgentDirectorying
    let hierarchy: HierarchicalOrchestrator
    let limits: OrchestrationLimits
    let userFacingRef: AgentRef

    /// Worker LLM runner installed for the duration of a user-facing turn.
    private let turnContext: TurnContextStore

    init(
        sessionID: String,
        directory: any AgentDirectorying,
        limits: OrchestrationLimits = .recommended
    ) {
        self.sessionID = sessionID
        self.directory = directory
        self.hierarchy = HierarchicalOrchestrator(directory: directory)
        self.limits = limits
        self.userFacingRef = AgentRef.userFacing(sessionID: sessionID)
        self.turnContext = TurnContextStore()
    }

    static func make(
        sessionID: String,
        repository: DBRepository,
        limits: OrchestrationLimits = .recommended
    ) async throws -> SessionOrchestrator {
        let directory = try await DBAgentDirectory(
            repository: repository,
            applicationName: await repository.applicationName,
            sessionID: sessionID,
            limits: limits
        )
        return SessionOrchestrator(sessionID: sessionID, directory: directory, limits: limits)
    }

    /// In-memory directory for tests and previews without DB persistence.
    static func makeInMemory(
        sessionID: String,
        limits: OrchestrationLimits = .recommended
    ) -> SessionOrchestrator {
        SessionOrchestrator(
            sessionID: sessionID,
            directory: InMemoryAgentDirectory(limits: limits),
            limits: limits
        )
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
        let caller = currentCaller()
        let outcome = try await hierarchy.spawnAndAwait(
            SpawnWorkerRequest(parent: caller, goal: goal, task: task, agentID: agentID),
            runTurn: runner
        )
        debugLog(
            "AgentRuntime: spawn \(outcome.child.agentID) status=\(outcome.status.rawValue) resultChars=\(outcome.result.count)"
        )
        return formatSpawnResult(outcome)
    }

    func completeTask(result: String, agentID: String? = nil) async throws -> String {
        // MCP handlers do not inherit TaskLocal from the worker LLM task; resolve via
        // explicit agent_id, TaskLocal (same-task path), or sole active worker turn.
        let worker = try await hierarchy.resolveWorkerForCompleteTask(
            sessionID: sessionID,
            agentID: agentID
        )
        try await hierarchy.completeTask(worker: worker, result: result)
        debugLog("AgentRuntime: complete_task agent=\(worker.agentID) resultChars=\(result.count)")
        return "task completed for \(worker.agentID)"
    }

    func listAgents(childrenOnly: Bool) async throws -> String {
        let caller = currentCaller()
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
        let from = currentCaller()
        try await hierarchy.send(from: from, toAgentID: toAgentID, message: message)
        return "message queued to \(toAgentID)"
    }

    func cancel(agentID: String) async throws -> String {
        let requester = currentCaller()
        let target = AgentRef(sessionID: sessionID, agentID: agentID)
        try await hierarchy.cancel(agent: target, by: requester)
        return "cancelled \(agentID)"
    }

    /// Prefer task-local caller (safe under concurrent workers); fall back to user-facing agent.
    private func currentCaller() -> AgentRef {
        AgentCallContext.caller ?? userFacingRef
    }

    private func formatSpawnResult(_ outcome: SpawnWorkerResult) -> String {
        """
        child_agent_id: \(outcome.child.agentID)
        status: \(outcome.status.rawValue)
        result:
        \(outcome.result)
        """
    }
}

// MARK: - Turn context

private actor TurnContextStore {
    private(set) var runner: (@Sendable (AgentRecord, AgentEnvelope) async throws -> String)?

    func setRunner(_ runner: (@Sendable (AgentRecord, AgentEnvelope) async throws -> String)?) {
        self.runner = runner
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
