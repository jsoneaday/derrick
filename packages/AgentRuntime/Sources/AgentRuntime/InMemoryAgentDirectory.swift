import Foundation
import ServiceContracts

/// In-process agent registry + serial mailbox processing (MA-0/MA-1).
public actor InMemoryAgentDirectory: AgentDirectorying {
    public let limits: OrchestrationLimits

    private struct RuntimeSlot {
        var record: AgentRecord
        var mailbox: InMemoryMailbox
        /// Serial chain: each deliver awaits the previous task for this agent.
        var turnTail: Task<Void, Never>?
    }

    private var slots: [AgentRef: RuntimeSlot] = [:]
    private var activeTurnCount: Int = 0
    private var concurrentWaiters: [CheckedContinuation<Void, Never>] = []
    private var turnErrors: [UUID: Error] = [:]

    public init(limits: OrchestrationLimits = .recommended) {
        self.limits = limits
    }

    public func record(for ref: AgentRef) async -> AgentRecord? {
        slots[ref]?.record
    }

    public func allRecords(sessionID: String) async -> [AgentRecord] {
        slots.values
            .map(\.record)
            .filter { $0.ref.sessionID == sessionID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func register(_ record: AgentRecord) async throws -> AgentRecord {
        if slots[record.ref] != nil {
            throw AgentRuntimeError.agentAlreadyExists(record.ref)
        }

        let sessionAgents = slots.keys.filter { $0.sessionID == record.ref.sessionID }.count
        guard sessionAgents < limits.maxAgentsPerSession else {
            throw AgentRuntimeError.sessionAgentLimitReached(limit: limits.maxAgentsPerSession)
        }

        if let parentID = record.parentAgentID {
            let parentRef = AgentRef(sessionID: record.ref.sessionID, agentID: parentID)
            guard let parentSlot = slots[parentRef] else {
                throw AgentRuntimeError.invalidParent(parentRef)
            }

            switch parentSlot.record.role {
            case .userFacing, .coordinator:
                break
            case .worker, .specialist:
                throw AgentRuntimeError.spawnNotAllowed(role: parentSlot.record.role)
            }

            let childCount = slots.values.filter {
                $0.record.ref.sessionID == record.ref.sessionID
                    && $0.record.parentAgentID == parentID
            }.count
            guard childCount < limits.maxChildrenPerAgent else {
                throw AgentRuntimeError.childLimitReached(parent: parentRef, limit: limits.maxChildrenPerAgent)
            }

            let parentDepth = depth(of: parentRef)
            let childDepth = parentDepth + 1
            guard childDepth <= limits.maxDepth else {
                throw AgentRuntimeError.depthLimitReached(limit: limits.maxDepth)
            }
        }

        var stored = record
        stored.updatedAt = .now
        let mailbox = InMemoryMailbox(ref: record.ref, limit: limits.maxMailboxDepth)
        slots[record.ref] = RuntimeSlot(record: stored, mailbox: mailbox, turnTail: nil)
        return stored
    }

    @discardableResult
    public func ensureUserFacingAgent(sessionID: String) async throws -> AgentRecord {
        let ref = AgentRef.userFacing(sessionID: sessionID)
        if let existing = slots[ref]?.record {
            return existing
        }
        return try await register(
            AgentRecord(
                ref: ref,
                role: .userFacing,
                status: .idle,
                goal: "User-facing conversation agent",
                systemOverlay: nil
            )
        )
    }

    /// Rehydrates a persisted agent without re-validating hierarchy caps (DB restore path).
    public func restore(_ record: AgentRecord) async throws {
        guard slots[record.ref] == nil else { return }
        let mailbox = InMemoryMailbox(ref: record.ref, limit: limits.maxMailboxDepth)
        slots[record.ref] = RuntimeSlot(record: record, mailbox: mailbox, turnTail: nil)
    }

    public func updateStatus(_ ref: AgentRef, status: AgentStatus) async throws {
        guard var slot = slots[ref] else {
            throw AgentRuntimeError.agentNotFound(ref)
        }
        slot.record.status = status
        slot.record.updatedAt = .now
        slots[ref] = slot
    }

    /// Enqueue an envelope without running a turn (e.g. parent receives taskResult while mid-tool-call).
    public func enqueueOnly(_ envelope: AgentEnvelope) async throws {
        guard let slot = slots[envelope.to] else {
            throw AgentRuntimeError.agentNotFound(envelope.to)
        }
        try await slot.mailbox.enqueue(envelope)
    }

    public func deliver(
        _ envelope: AgentEnvelope,
        execute: nonisolated(nonsending) @escaping @Sendable (AgentEnvelope) async throws -> Void
    ) async throws {
        guard var slot = slots[envelope.to] else {
            throw AgentRuntimeError.agentNotFound(envelope.to)
        }

        try await slot.mailbox.enqueue(envelope)

        let previous = slot.turnTail
        let directory = self

        let task = Task<Void, Never> {
            _ = await previous?.value
            do {
                try await directory.runTurn(envelope: envelope, execute: execute)
            } catch {
                await directory.storeTurnError(envelopeID: envelope.id, error: error)
            }
        }

        slot.turnTail = task
        slots[envelope.to] = slot

        await task.value
        if let error = turnErrors.removeValue(forKey: envelope.id) {
            throw error
        }
    }

    // MARK: - Internals

    private func storeTurnError(envelopeID: UUID, error: Error) {
        turnErrors[envelopeID] = error
    }

    private func depth(of ref: AgentRef) -> Int {
        var current = ref
        var d = 0
        while let parentID = slots[current]?.record.parentAgentID {
            d += 1
            current = AgentRef(sessionID: ref.sessionID, agentID: parentID)
            if d > limits.maxDepth + 8 { break }
        }
        return d
    }

    private func acquireConcurrentTurnSlot() async {
        if activeTurnCount < limits.maxConcurrentTurns {
            activeTurnCount += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            concurrentWaiters.append(continuation)
        }
        activeTurnCount += 1
    }

    private func releaseConcurrentTurnSlot() {
        activeTurnCount = max(0, activeTurnCount - 1)
        if !concurrentWaiters.isEmpty {
            concurrentWaiters.removeFirst().resume()
        }
    }

    private func runTurn(
        envelope: AgentEnvelope,
        execute: nonisolated(nonsending) @Sendable (AgentEnvelope) async throws -> Void
    ) async throws {
        if var slot = slots[envelope.to] {
            _ = await slot.mailbox.dequeue()
            slot.record.status = .running
            slot.record.updatedAt = .now
            slots[envelope.to] = slot
        }

        await acquireConcurrentTurnSlot()
        do {
            try await execute(envelope)
            finishTurn(ref: envelope.to, failed: false)
        } catch {
            finishTurn(ref: envelope.to, failed: true)
            throw error
        }
    }

    private func finishTurn(ref: AgentRef, failed: Bool) {
        releaseConcurrentTurnSlot()
        if var slot = slots[ref] {
            slot.record.status = failed ? .failed : .idle
            slot.record.updatedAt = .now
            slots[ref] = slot
        }
    }
}
