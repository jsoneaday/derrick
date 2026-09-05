import Foundation
import Testing
import Structure
@testable import AgentRuntime

@Suite struct AgentRuntimeTests {
    @Test func envelopeUserMessageRoundTripCodable() throws {
        let ref = AgentRef.userFacing(sessionID: "s1")
        let original = AgentEnvelope.userMessage(to: ref, body: "hello", correlationId: "c1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentEnvelope.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.to == original.to)
        #expect(decoded.body == "hello")
        #expect(decoded.kind == .userMessage)
        #expect(decoded.correlationId == "c1")
        if case .user = decoded.from {
            // ok
        } else {
            Issue.record("expected .user source")
        }
    }

    @Test func mailboxIsFIFO() async throws {
        let ref = AgentRef(sessionID: "s", agentID: "a")
        let box = InMemoryMailbox(ref: ref, limit: 8)
        let e1 = AgentEnvelope.userMessage(to: ref, body: "one")
        let e2 = AgentEnvelope.userMessage(to: ref, body: "two")
        try await box.enqueue(e1)
        try await box.enqueue(e2)
        #expect(await box.peekCount() == 2)
        let first = await box.dequeue()
        let second = await box.dequeue()
        #expect(first?.body == "one")
        #expect(second?.body == "two")
        #expect(await box.dequeue() == nil)
    }

    @Test func mailboxEnforcesLimit() async throws {
        let ref = AgentRef(sessionID: "s", agentID: "a")
        let box = InMemoryMailbox(ref: ref, limit: 1)
        try await box.enqueue(AgentEnvelope.userMessage(to: ref, body: "one"))
        do {
            try await box.enqueue(AgentEnvelope.userMessage(to: ref, body: "two"))
            Issue.record("expected mailboxFull")
        } catch let error as AgentRuntimeError {
            #expect(error == .mailboxFull(ref, limit: 1))
        }
    }

    @Test func ensureUserFacingAndDeliverSerialTurns() async throws {
        let directory = InMemoryAgentDirectory(limits: .recommended)
        let sessionID = UUID().uuidString
        let record = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        #expect(record.role == .userFacing)
        #expect(record.ref.agentID == AgentRef.userFacingAgentID)

        let order = OrderBox()
        let e1 = AgentEnvelope.userMessage(to: record.ref, body: "first")
        let e2 = AgentEnvelope.userMessage(to: record.ref, body: "second")

        async let t1: Void = directory.deliver(e1) { env in
            await order.append(env.body)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        async let t2: Void = directory.deliver(e2) { env in
            await order.append(env.body)
        }
        try await t1
        try await t2
        let values = await order.values()
        #expect(values == ["first", "second"])
    }

    @Test func sessionAgentLimit() async throws {
        let limits = OrchestrationLimits(maxAgentsPerSession: 1)
        let directory = InMemoryAgentDirectory(limits: limits)
        _ = try await directory.ensureUserFacingAgent(sessionID: "s")
        do {
            try await directory.register(
                AgentRecord(
                    ref: AgentRef(sessionID: "s", agentID: "worker-1"),
                    role: .worker,
                    parentAgentID: AgentRef.userFacingAgentID
                )
            )
            Issue.record("expected sessionAgentLimitReached")
        } catch let error as AgentRuntimeError {
            #expect(error == .sessionAgentLimitReached(limit: 1))
        }
    }

    @Test func workerCannotSpawnChildren() async throws {
        let directory = InMemoryAgentDirectory()
        let sessionID = "s"
        _ = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        _ = try await directory.register(
            AgentRecord(
                ref: AgentRef(sessionID: sessionID, agentID: "w1"),
                role: .worker,
                parentAgentID: AgentRef.userFacingAgentID
            )
        )
        do {
            try await directory.register(
                AgentRecord(
                    ref: AgentRef(sessionID: sessionID, agentID: "w2"),
                    role: .worker,
                    parentAgentID: "w1"
                )
            )
            Issue.record("expected spawnNotAllowed")
        } catch let error as AgentRuntimeError {
            #expect(error == .spawnNotAllowed(role: .worker))
        }
    }

    @Test func depthLimitBlocksGrandchild() async throws {
        let limits = OrchestrationLimits(maxDepth: 1, maxChildrenPerAgent: 4, maxAgentsPerSession: 8)
        let directory = InMemoryAgentDirectory(limits: limits)
        let sessionID = "s"
        _ = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        _ = try await directory.register(
            AgentRecord(
                ref: AgentRef(sessionID: sessionID, agentID: "coord"),
                role: .coordinator,
                parentAgentID: AgentRef.userFacingAgentID
            )
        )
        do {
            try await directory.register(
                AgentRecord(
                    ref: AgentRef(sessionID: sessionID, agentID: "deep"),
                    role: .worker,
                    parentAgentID: "coord"
                )
            )
            Issue.record("expected depthLimitReached")
        } catch let error as AgentRuntimeError {
            #expect(error == .depthLimitReached(limit: 1))
        }
    }

    @Test func deliverPropagatesExecuteError() async throws {
        let directory = InMemoryAgentDirectory()
        let record = try await directory.ensureUserFacingAgent(sessionID: "s")
        let envelope = AgentEnvelope.userMessage(to: record.ref, body: "x")
        do {
            try await directory.deliver(envelope) { _ in
                throw AgentRuntimeError.turnInProgress(record.ref)
            }
            Issue.record("expected error")
        } catch let error as AgentRuntimeError {
            #expect(error == .turnInProgress(record.ref))
        }
    }

    @Test func recommendedLimitsDefaults() {
        let l = OrchestrationLimits.recommended
        #expect(l.maxDepth == 2)
        #expect(l.maxChildrenPerAgent == 4)
        #expect(l.maxConcurrentTurns == 4)
        #expect(l.maxAgentsPerSession == 8)
    }

    @Test func spawnAndAwaitReturnsWorkerResult() async throws {
        let directory = InMemoryAgentDirectory()
        let hierarchy = HierarchicalOrchestrator(directory: directory)
        let sessionID = "s-spawn"
        _ = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        let parent = AgentRef.userFacing(sessionID: sessionID)

        let outcome = try await hierarchy.spawnAndAwait(
            SpawnWorkerRequest(parent: parent, goal: "research", task: "find X", agentID: "w-research")
        ) { child, envelope in
            #expect(child.ref.agentID == "w-research")
            #expect(envelope.kind == .taskAssign)
            #expect(envelope.body.contains("find X"))
            return "answer-42"
        }

        #expect(outcome.child.agentID == "w-research")
        #expect(outcome.result == "answer-42")
        #expect(outcome.status == .completed)

        let children = await hierarchy.listChildren(of: parent)
        #expect(children.count == 1)
        #expect(children.first?.status == .completed)
    }

    @Test func completeTaskOverridesTurnText() async throws {
        let directory = InMemoryAgentDirectory()
        let hierarchy = HierarchicalOrchestrator(directory: directory)
        let sessionID = "s-complete"
        _ = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        let parent = AgentRef.userFacing(sessionID: sessionID)

        let outcome = try await hierarchy.spawnAndAwait(
            SpawnWorkerRequest(parent: parent, goal: "g", task: "t", agentID: "w1")
        ) { child, _ in
            try await hierarchy.completeTask(worker: child.ref, result: "explicit-result")
            return "ignored-turn-text"
        }
        #expect(outcome.result == "explicit-result")
    }

    @Test func completeTaskResolvesSoleActiveWorkerWithoutAgentID() async throws {
        let directory = InMemoryAgentDirectory()
        let hierarchy = HierarchicalOrchestrator(directory: directory)
        let sessionID = "s-resolve"
        _ = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        let parent = AgentRef.userFacing(sessionID: sessionID)

        let outcome = try await hierarchy.spawnAndAwait(
            SpawnWorkerRequest(parent: parent, goal: "g", task: "t", agentID: "solo-worker")
        ) { _, _ in
            // Simulate MCP path: no TaskLocal, no agent_id — sole active worker.
            let resolved = try await hierarchy.resolveWorkerForCompleteTask(sessionID: sessionID, agentID: nil)
            #expect(resolved.agentID == "solo-worker")
            try await hierarchy.completeTask(worker: resolved, result: "via-active-set")
            return "ignored"
        }
        #expect(outcome.result == "via-active-set")
    }

    @Test func completeTaskRequiresAgentIDWhenMultipleActive() async throws {
        let directory = InMemoryAgentDirectory(
            limits: OrchestrationLimits(maxConcurrentTurns: 4, maxAgentsPerSession: 8)
        )
        let hierarchy = HierarchicalOrchestrator(directory: directory)
        let sessionID = "s-ambig"
        _ = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        let parent = AgentRef.userFacing(sessionID: sessionID)

        let gate = AsyncGate()
        async let r1: SpawnWorkerResult = hierarchy.spawnAndAwait(
            SpawnWorkerRequest(parent: parent, goal: "a", task: "t", agentID: "w-a")
        ) { _, _ in
            await gate.enter()
            await gate.waitForRelease()
            // Explicit agent_id path (MCP-like, no reliance on TaskLocal).
            let resolved = try await hierarchy.resolveWorkerForCompleteTask(sessionID: sessionID, agentID: "w-a")
            try await hierarchy.completeTask(worker: resolved, result: "a-done")
            return "a"
        }
        async let r2: SpawnWorkerResult = hierarchy.spawnAndAwait(
            SpawnWorkerRequest(parent: parent, goal: "b", task: "t", agentID: "w-b")
        ) { _, _ in
            await gate.enter()
            await gate.waitForRelease()
            let resolved = try await hierarchy.resolveWorkerForCompleteTask(sessionID: sessionID, agentID: "w-b")
            try await hierarchy.completeTask(worker: resolved, result: "b-done")
            return "b"
        }
        await gate.waitUntilEntered(count: 2)
        // Outside worker TaskLocal: two active workers → must pass agent_id.
        do {
            _ = try await hierarchy.resolveWorkerForCompleteTask(sessionID: sessionID, agentID: nil)
            Issue.record("expected completeTaskAmbiguousWorkers")
        } catch let error as AgentRuntimeError {
            if case .completeTaskAmbiguousWorkers(let ids) = error {
                #expect(Set(ids) == Set(["w-a", "w-b"]))
            } else {
                Issue.record("wrong error \(error)")
            }
        }
        await gate.releaseAll()
        let results = try await [r1, r2]
        #expect(Set(results.map(\.result)) == Set(["a-done", "b-done"]))
    }

    @Test func runtimeErrorsAreHumanReadable() {
        let err = AgentRuntimeError.completeTaskNoActiveWorker
        #expect(err.errorDescription?.contains("agents_complete_task") == true)
        let ambig = AgentRuntimeError.completeTaskAmbiguousWorkers(agentIDs: ["w1", "w2"])
        #expect(ambig.errorDescription?.contains("w1") == true)
    }

    @Test func spawnManyRunsConcurrently() async throws {
        let directory = InMemoryAgentDirectory(
            limits: OrchestrationLimits(maxConcurrentTurns: 4, maxAgentsPerSession: 8)
        )
        let hierarchy = HierarchicalOrchestrator(directory: directory)
        let sessionID = "s-fanout"
        _ = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        let parent = AgentRef.userFacing(sessionID: sessionID)

        let box = ConcurrentBox()
        let requests = [
            SpawnWorkerRequest(parent: parent, goal: "a", task: "task-a", agentID: "wa"),
            SpawnWorkerRequest(parent: parent, goal: "b", task: "task-b", agentID: "wb"),
            SpawnWorkerRequest(parent: parent, goal: "c", task: "task-c", agentID: "wc")
        ]
        let results = try await hierarchy.spawnManyAndAwait(requests) { child, _ in
            await box.markStarted()
            // If sequential, 3 × 80ms >> 200ms; concurrent should finish near one delay.
            try await Task.sleep(nanoseconds: 80_000_000)
            await box.markFinished()
            return "ok-\(child.ref.agentID)"
        }
        #expect(results.count == 3)
        #expect(Set(results.map(\.child.agentID)) == Set(["wa", "wb", "wc"]))
        #expect(results.map(\.result).sorted() == ["ok-wa", "ok-wb", "ok-wc"].sorted())
        let peak = await box.peakConcurrent()
        #expect(peak >= 2)
        // Avoid wall-clock thresholds; CI runners vary. Peak concurrency proves fan-out.
    }

    @Test func sendRejectsUnrelatedAgents() async throws {
        let directory = InMemoryAgentDirectory()
        let hierarchy = HierarchicalOrchestrator(directory: directory)
        let sessionID = "s-send"
        _ = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        _ = try await directory.register(
            AgentRecord(
                ref: AgentRef(sessionID: sessionID, agentID: "w1"),
                role: .worker,
                parentAgentID: AgentRef.userFacingAgentID
            )
        )
        _ = try await directory.register(
            AgentRecord(
                ref: AgentRef(sessionID: sessionID, agentID: "w2"),
                role: .worker,
                parentAgentID: AgentRef.userFacingAgentID
            )
        )
        do {
            try await hierarchy.send(
                from: AgentRef(sessionID: sessionID, agentID: "w1"),
                toAgentID: "w2",
                message: "hi"
            )
            Issue.record("expected notRelatedAgents")
        } catch let error as AgentRuntimeError {
            #expect(
                error == .notRelatedAgents(
                    from: AgentRef(sessionID: sessionID, agentID: "w1"),
                    to: AgentRef(sessionID: sessionID, agentID: "w2")
                )
            )
        }
    }
}

private actor OrderBox {
    private var items: [String] = []
    func append(_ value: String) { items.append(value) }
    func values() -> [String] { items }
}

private actor ConcurrentBox {
    private var active = 0
    private var peak = 0
    func markStarted() {
        active += 1
        peak = max(peak, active)
    }
    func markFinished() {
        active = max(0, active - 1)
    }
    func peakConcurrent() -> Int { peak }
}

/// Simple barrier for concurrent worker tests.
private actor AsyncGate {
    private var entered = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered += 1
        if !enterWaiters.isEmpty {
            let copy = enterWaiters
            enterWaiters.removeAll()
            for w in copy { w.resume() }
        }
    }

    func waitUntilEntered(count: Int) async {
        while entered < count {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                enterWaiters.append(c)
            }
        }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    func releaseAll() {
        released = true
        let copy = waiters
        waiters.removeAll()
        for w in copy { w.resume() }
    }
}
