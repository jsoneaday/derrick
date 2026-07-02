import Testing
@testable import MemorySystem

@Suite struct MemorySystemTests {
    @Test func keywordFilterRemovesToolAndModelNames() {
        let filter = MemoryKeywordFilter()
        let keywords = filter.filter(["user intent", "tool", "gemini", "session replay", "mcp"])

        #expect(keywords == ["user intent", "session replay"])
    }

    @Test func compactionPolicyTargetsOldestEntriesFirst() {
        let policy = TieredMemoryCompactionPolicy()
        let sessionKey = MemorySessionKey(sessionID: "s", agentID: "a")
        let older = MemoryWorkingEntry(
            sessionKey: sessionKey,
            createdAt: .distantPast,
            rawPair: PromptResponsePair(sessionID: "s", agentID: "a", prompt: "old prompt", completion: "old completion")
        )
        let newer = MemoryWorkingEntry(
            sessionKey: sessionKey,
            createdAt: .now,
            rawPair: PromptResponsePair(sessionID: "s", agentID: "a", prompt: "new prompt", completion: "new completion")
        )

        let plan = policy.plan(entries: [newer, older], budget: MemoryBudget(maxTokenCount: 1))

        #expect(plan.instructions.contains(.summarize(older.id)))
    }

    @Test func compactionPolicyDropsCompressedSummaryLast() {
        let policy = TieredMemoryCompactionPolicy()
        let sessionKey = MemorySessionKey(sessionID: "s", agentID: "a")
        let compressed = MemorySummary(
            text: "compressed",
            metadata: MemorySummaryMetadata(
                keywords: [],
                compressionRatio: 0.5,
                sourceTokenCount: 10,
                summaryTokenCount: 2
            )
        )
        let entry = MemoryWorkingEntry(
            sessionKey: sessionKey,
            createdAt: .distantPast,
            compressedSummary: compressed
        )

        let plan = policy.plan(entries: [entry], budget: MemoryBudget(maxTokenCount: 1))

        #expect(plan.instructions.contains(.dropCompressed(entry.id)))
    }

    @Test func memoryBudgetUsesModelSpecificWorkingSetLimits() {
        #expect(MemoryBudget.maxTokenCount(forProvider: "gemini", modelName: "gemini-2.5-flash-lite") == 50_000)
        #expect(MemoryBudget.maxTokenCount(forProvider: "gemini", modelName: "gemini-3.1-flash-lite") == 50_000)
        #expect(MemoryBudget.maxTokenCount(forProvider: "openai", modelName: "gpt-5-mini") == 25_000)
    }

    @Test func retrievalPrefersCompactedWorkingSetStateOverPersistedRecord() async throws {
        let coordinator = MemoryCoordinator(
            store: InMemoryMemoryStore(),
            summarizer: StubMemorySummarizer(),
            policy: TieredMemoryCompactionPolicy(),
            budget: MemoryBudget(maxTokenCount: 1)
        )
        let sessionKey = MemorySessionKey(sessionID: "s", agentID: "a")

        try await coordinator.ingest(
            MemoryIngestInput(
                sessionKey: sessionKey,
                prompt: "prompt",
                completion: "completion"
            )
        )

        let result = try await coordinator.retrieve(MemoryRetrievalRequest(sessionKey: sessionKey, limit: 10))

        #expect(result.entries.count == 1)
        #expect(result.entries.first?.compressedSummary != nil)
    }

    @Test func priorRetrievalReturnsNewestPastSessionsWithPaging() async throws {
        let store = InMemoryMemoryStore()
        let coordinator = MemoryCoordinator(
            store: store,
            summarizer: StubMemorySummarizer(),
            policy: TieredMemoryCompactionPolicy(),
            budget: MemoryBudget(maxTokenCount: 1)
        )
        let currentSession = MemorySessionKey(sessionID: "current", agentID: "a")

        try await store.upsert(makeRecord(
            sessionID: "older",
            agentID: "a",
            createdAt: Date(timeIntervalSince1970: 10),
            prompt: "older prompt"
        ))
        try await store.upsert(makeRecord(
            sessionID: "newer",
            agentID: "a",
            createdAt: Date(timeIntervalSince1970: 20),
            prompt: "newer prompt"
        ))
        try await store.upsert(makeRecord(
            sessionID: "current",
            agentID: "a",
            createdAt: Date(timeIntervalSince1970: 30),
            prompt: "current prompt"
        ))

        let result = try await coordinator.retrievePrior(
            MemoryPriorRetrievalRequest(
                sessionKey: currentSession,
                limit: 1,
                page: 2
            )
        )

        #expect(result.entries.count == 1)
        #expect(result.entries.first?.pair.prompt == "older prompt")
    }
}

private struct StubMemorySummarizer: MemorySummarizer {
    func summarize(_ pair: PromptResponsePair) async throws -> MemorySummaryPair {
        let summary = MemorySummary(
            text: "summary",
            metadata: MemorySummaryMetadata(
                keywords: [],
                compressionRatio: 0.5,
                sourceTokenCount: pair.totalTokenCount,
                summaryTokenCount: 1
            )
        )
        return MemorySummaryPair(layer1: summary, layer2: summary)
    }
}

private func makeRecord(sessionID: String, agentID: String, createdAt: Date, prompt: String) -> MemoryRecord {
    let pair = PromptResponsePair(
        sessionID: sessionID,
        agentID: agentID,
        prompt: prompt,
        completion: "completion",
        createdAt: createdAt
    )
    return MemoryRecord(id: pair.id, pair: pair)
}
