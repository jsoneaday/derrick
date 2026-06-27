import Foundation
import LLMAgentClient

final class ConversationModel {
    let sessionKey: MemorySessionKey
    let memoryCoordinator: MemoryCoordinator

    init() {
        self.sessionKey = MemorySessionKey(sessionID: UUID().uuidString, agentID: "ui")

        let summarizer = GeminiMemorySummarizer()
        self.memoryCoordinator = MemoryCoordinator(
            store: InMemoryMemoryStore(),
            summarizer: summarizer,
            policy: TieredMemoryCompactionPolicy(),
            budget: MemoryBudget(maxTokenCount: 1_500)
        )
    }

    func stream(prompt: String, apiKey: String) async -> AsyncThrowingStream<String, Error> {
        let provider = GeminiProvider(apiKey: apiKey)
        let client = GeminiAgentClient(provider: provider)
        let pipeline = ConversationPipeline(
            sessionKey: sessionKey,
            memoryCoordinator: memoryCoordinator,
            client: client,
            model: .gemini31FlashLite,
            retrievalLimit: 5
        )

        return await pipeline.stream(prompt: prompt)
    }
}
