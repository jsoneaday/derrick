import Foundation
import LLMAgentClient

final class ConversationModel {
    let sessionKey: MemorySessionKey
    let memoryCoordinator: MemoryCoordinator
    let model: GeminiModel

    init() {
        self.sessionKey = MemorySessionKey(sessionID: UUID().uuidString, agentID: "ui")
        self.model = .gemini31FlashLite

        let summarizer = GeminiMemorySummarizer()
        self.memoryCoordinator = MemoryCoordinator(
            store: InMemoryMemoryStore(),
            summarizer: summarizer,
            policy: TieredMemoryCompactionPolicy(),
            budget: MemoryBudget(provider: model.id.provider, modelName: model.id.rawValue)
        )
    }

    func stream(prompt: String, apiKey: String) async -> AsyncThrowingStream<String, Error> {
        let provider = GeminiProvider(apiKey: apiKey)
        let client = GeminiAgentClient(provider: provider)
        let pipeline = ConversationPipeline(
            sessionKey: sessionKey,
            memoryCoordinator: memoryCoordinator,
            client: client,
            model: model,
            retrievalLimit: 5
        )

        return await pipeline.stream(prompt: prompt)
    }
}
