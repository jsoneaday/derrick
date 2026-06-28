import Foundation
import DBRepository
import LLMAgentClient

@MainActor
final class ConversationModel {
    let sessionKey: MemorySessionKey
    let memoryCoordinator: MemoryCoordinator
    let model: GeminiModel
    let databaseDirectoryURL: URL

    private init(
        sessionKey: MemorySessionKey,
        memoryCoordinator: MemoryCoordinator,
        model: GeminiModel,
        databaseDirectoryURL: URL
    ) {
        self.sessionKey = sessionKey
        self.memoryCoordinator = memoryCoordinator
        self.model = model
        self.databaseDirectoryURL = databaseDirectoryURL
    }

    static func makeDefault() async -> ConversationModel {
        let sessionKey = MemorySessionKey(sessionID: UUID().uuidString, agentID: "ui")
        let model: GeminiModel = .gemini31FlashLite
        let fallbackDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ui", isDirectory: true)
        let databaseDirectoryURL = (try? AppDatabaseDirectory.resolve(applicationName: "ui")) ?? fallbackDirectoryURL

        let budget = MemoryBudget(provider: model.id.provider, modelName: model.id.rawValue)
        let summarizer = GeminiMemorySummarizer()

        if let repository = try? await makeMemoryStore(
            applicationName: "ui",
            databaseDirectoryURL: databaseDirectoryURL
        ) {
            let memoryCoordinator = MemoryCoordinator(
                store: repository,
                summarizer: summarizer,
                policy: TieredMemoryCompactionPolicy(),
                budget: budget
            )
            return ConversationModel(
                sessionKey: sessionKey,
                memoryCoordinator: memoryCoordinator,
                model: model,
                databaseDirectoryURL: await repository.databaseDirectoryURL
            )
        }

        let memoryCoordinator = MemoryCoordinator(
            store: InMemoryMemoryStore(),
            summarizer: summarizer,
            policy: TieredMemoryCompactionPolicy(),
            budget: budget
        )
        return ConversationModel(
            sessionKey: sessionKey,
            memoryCoordinator: memoryCoordinator,
            model: model,
            databaseDirectoryURL: databaseDirectoryURL
        )
    }

    private static func makeMemoryStore(
        applicationName: String,
        databaseDirectoryURL: URL
    ) async throws -> DBRepository {
        let repository = DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: applicationName,
                databaseName: "derrick",
                databaseDirectoryURL: databaseDirectoryURL,
                username: "ui",
                password: "ui"
            )
        )

        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        return repository
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
