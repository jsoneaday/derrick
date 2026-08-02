import Foundation
import Testing
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
