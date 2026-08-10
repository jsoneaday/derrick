import Foundation

public struct SpawnWorkerRequest: Sendable, Hashable {
    public let parent: AgentRef
    public let goal: String
    public let task: String
    public let agentID: String?

    public init(parent: AgentRef, goal: String, task: String, agentID: String? = nil) {
        self.parent = parent
        self.goal = goal
        self.task = task
        self.agentID = agentID
    }
}

public struct SpawnWorkerResult: Sendable, Hashable {
    public let child: AgentRef
    public let result: String
    public let status: AgentStatus

    public init(child: AgentRef, result: String, status: AgentStatus) {
        self.child = child
        self.result = result
        self.status = status
    }
}

/// Hierarchical task protocol helpers on top of `AgentDirectorying`.
///
/// Spawn-and-await runs a worker turn via the supplied executor and returns the result
/// to the parent tool call (mailbox + serial turns still apply).
public actor HierarchicalOrchestrator {
    private let directory: any AgentDirectorying

    /// Results reported via `agents_complete_task` during a worker turn (keyed by child ref).
    private var explicitTaskResults: [AgentRef: String] = [:]
    /// Agents cancelled while running.
    private var cancelled: Set<AgentRef> = []
    /// Worker turns currently inside `runTurn` (for complete_task identity when TaskLocal is unavailable across MCP).
    private var activeWorkerTurns: Set<AgentRef> = []

    public init(directory: any AgentDirectorying) {
        self.directory = directory
    }

    /// Active worker refs for a session (used to resolve `agents_complete_task` without TaskLocal).
    public func activeWorkers(sessionID: String) -> [AgentRef] {
        activeWorkerTurns.filter { $0.sessionID == sessionID }.sorted { $0.agentID < $1.agentID }
    }

    /// Resolve which worker is completing a task.
    /// Prefer explicit `agentID`, then TaskLocal caller, then the sole active worker.
    public func resolveWorkerForCompleteTask(
        sessionID: String,
        agentID: String?
    ) throws -> AgentRef {
        if let raw = agentID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return AgentRef(sessionID: sessionID, agentID: raw)
        }
        if let caller = AgentCallContext.caller, caller.sessionID == sessionID {
            return caller
        }
        let active = activeWorkers(sessionID: sessionID)
        if active.count == 1 {
            return active[0]
        }
        if active.isEmpty {
            throw AgentRuntimeError.completeTaskNoActiveWorker
        }
        throw AgentRuntimeError.completeTaskAmbiguousWorkers(agentIDs: active.map(\.agentID))
    }

    /// Creates a worker child and runs one task-assign turn to completion.
    public func spawnAndAwait(
        _ request: SpawnWorkerRequest,
        runTurn: @escaping @Sendable (_ child: AgentRecord, _ envelope: AgentEnvelope) async throws -> String
    ) async throws -> SpawnWorkerResult {
        try await spawnOne(request, runTurn: runTurn)
    }

    /// Fan-out: run multiple worker spawns concurrently (order of results matches `requests`).
    /// Concurrency is bounded by the directory's `maxConcurrentTurns` cap.
    public func spawnManyAndAwait(
        _ requests: [SpawnWorkerRequest],
        runTurn: @escaping @Sendable (_ child: AgentRecord, _ envelope: AgentEnvelope) async throws -> String
    ) async throws -> [SpawnWorkerResult] {
        guard !requests.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (Int, SpawnWorkerResult).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let result = try await self.spawnOne(request, runTurn: runTurn)
                    return (index, result)
                }
            }
            var ordered = Array<SpawnWorkerResult?>(repeating: nil, count: requests.count)
            for try await (index, result) in group {
                ordered[index] = result
            }
            return ordered.compactMap { $0 }
        }
    }

    private func spawnOne(
        _ request: SpawnWorkerRequest,
        runTurn: @escaping @Sendable (_ child: AgentRecord, _ envelope: AgentEnvelope) async throws -> String
    ) async throws -> SpawnWorkerResult {
        guard let parentRecord = await directory.record(for: request.parent) else {
            throw AgentRuntimeError.agentNotFound(request.parent)
        }
        switch parentRecord.role {
        case .userFacing, .coordinator:
            break
        case .worker, .specialist:
            throw AgentRuntimeError.spawnNotAllowed(role: parentRecord.role)
        }

        let childID = sanitizedAgentID(request.agentID) ?? "worker-\(UUID().uuidString.prefix(8))"
        let childRef = AgentRef(sessionID: request.parent.sessionID, agentID: childID)

        let childRecord = try await directory.register(
            AgentRecord(
                ref: childRef,
                role: .worker,
                parentAgentID: request.parent.agentID,
                status: .created,
                goal: request.goal,
                systemOverlay: WorkerOverlays.workerDefault
            )
        )

        let correlation = UUID().uuidString
        let assign = AgentEnvelope.taskAssign(
            to: childRef,
            from: request.parent,
            body: """
            Agent-ID: \(childID)
            Goal: \(request.goal)

            Task:
            \(request.task)

            When finished: prefer agents_complete_task with result and agent_id "\(childID)". Otherwise complete with the full answer in assistant_response—never a meta excuse.
            """,
            correlationId: correlation
        )

        let turnTextBox = TurnTextBox()
        do {
            try await directory.deliver(assign) { envelope in
                if await self.isCancelled(childRef) {
                    throw AgentRuntimeError.agentCancelled(childRef)
                }
                await self.beginWorkerTurn(childRef)
                do {
                    // Task-local when same task tree; activeWorkerTurns covers MCP handlers.
                    let text = try await AgentCallContext.$caller.withValue(childRef) {
                        try await runTurn(childRecord, envelope)
                    }
                    await turnTextBox.set(text)
                    await self.endWorkerTurn(childRef)
                } catch {
                    await self.endWorkerTurn(childRef)
                    throw error
                }
            }
        } catch {
            try? await directory.updateStatus(childRef, status: .failed)
            throw error
        }

        if isCancelled(childRef) {
            try? await directory.updateStatus(childRef, status: .cancelled)
            return SpawnWorkerResult(child: childRef, result: "cancelled", status: .cancelled)
        }

        let explicit = explicitTaskResults.removeValue(forKey: childRef)
        let turnText = await turnTextBox.value
        let resultBody = (explicit?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? turnText.trimmingCharacters(in: .whitespacesAndNewlines)

        let resultEnvelope = AgentEnvelope.taskResult(
            to: request.parent,
            from: childRef,
            body: resultBody.isEmpty ? "(empty worker result)" : resultBody,
            correlationId: correlation
        )
        // Enqueue result for parent without running a parent turn (parent is mid-tool-call).
        try? await noteEnvelopeOnMailbox(resultEnvelope)

        try await directory.updateStatus(childRef, status: .completed)
        return SpawnWorkerResult(
            child: childRef,
            result: resultBody.isEmpty ? "(empty worker result)" : resultBody,
            status: .completed
        )
    }

    /// Worker reports explicit task completion.
    public func completeTask(worker: AgentRef, result: String) async throws {
        guard let record = await directory.record(for: worker) else {
            throw AgentRuntimeError.agentNotFound(worker)
        }
        guard record.role == .worker || record.role == .specialist else {
            throw AgentRuntimeError.spawnNotAllowed(role: record.role)
        }
        explicitTaskResults[worker] = result
        try await directory.updateStatus(worker, status: .completed)
    }

    private func beginWorkerTurn(_ ref: AgentRef) {
        activeWorkerTurns.insert(ref)
    }

    private func endWorkerTurn(_ ref: AgentRef) {
        activeWorkerTurns.remove(ref)
    }

    public func listAgents(sessionID: String) async -> [AgentRecord] {
        await directory.allRecords(sessionID: sessionID)
    }

    public func listChildren(of parent: AgentRef) async -> [AgentRecord] {
        await directory.allRecords(sessionID: parent.sessionID).filter {
            $0.parentAgentID == parent.agentID
        }
    }

    /// Parent/child-only message (peer not allowed in MA-2).
    public func send(
        from: AgentRef,
        toAgentID: String,
        message: String
    ) async throws {
        let to = AgentRef(sessionID: from.sessionID, agentID: toAgentID)
        guard let fromRecord = await directory.record(for: from) else {
            throw AgentRuntimeError.agentNotFound(from)
        }
        guard let toRecord = await directory.record(for: to) else {
            throw AgentRuntimeError.agentNotFound(to)
        }

        let related: Bool = {
            if fromRecord.parentAgentID == to.agentID { return true }
            if toRecord.parentAgentID == from.agentID { return true }
            return false
        }()
        guard related else {
            throw AgentRuntimeError.notRelatedAgents(from: from, to: to)
        }

        let envelope = AgentEnvelope(
            to: to,
            from: .agent(from),
            kind: .agentMessage,
            body: message
        )
        try await noteEnvelopeOnMailbox(envelope)
    }

    public func cancel(agent: AgentRef, by requester: AgentRef) async throws {
        guard let record = await directory.record(for: agent) else {
            throw AgentRuntimeError.agentNotFound(agent)
        }
        // Parent or self may cancel.
        let allowed = requester == agent
            || record.parentAgentID == requester.agentID
            || requester.agentID == AgentRef.userFacingAgentID
        guard allowed else {
            throw AgentRuntimeError.spawnNotAllowed(role: .worker)
        }
        cancelled.insert(agent)
        try await directory.updateStatus(agent, status: .cancelled)
    }

    public func isCancelled(_ ref: AgentRef) -> Bool {
        cancelled.contains(ref)
    }

    // MARK: - Helpers

    private func noteEnvelopeOnMailbox(_ envelope: AgentEnvelope) async throws {
        // Use deliver with no-op execute so the envelope is recorded through the same path
        // without starting an LLM turn for the parent mid-call.
        // For taskResult / agentMessage we only enqueue via a lightweight internal API:
        try await directory.enqueueOnly(envelope)
    }

    private func sanitizedAgentID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return String(filtered.prefix(64))
    }
}

private actor TurnTextBox {
    private(set) var value: String = ""
    func set(_ text: String) { value = text }
}
