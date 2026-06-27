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
}
