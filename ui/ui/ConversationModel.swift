import Foundation
import DBRepository
import LLMAgentClient
import MCPClient
import MCPServer

@MainActor
final class ConversationModel {
    let sessionKey: MemorySessionKey
    let memoryCoordinator: MemoryCoordinator
    let mcpBridge: MCPLocalBridge
    let model: GeminiModel
    let databaseDirectoryURL: URL
    let ragInstructions: String
    let mcpToolInstructions: String
    let mcpToolLoopInstructions: String

    private init(
        sessionKey: MemorySessionKey,
        memoryCoordinator: MemoryCoordinator,
        mcpBridge: MCPLocalBridge,
        model: GeminiModel,
        databaseDirectoryURL: URL,
        ragInstructions: String,
        mcpToolInstructions: String,
        mcpToolLoopInstructions: String
    ) {
        self.sessionKey = sessionKey
        self.memoryCoordinator = memoryCoordinator
        self.mcpBridge = mcpBridge
        self.model = model
        self.databaseDirectoryURL = databaseDirectoryURL
        self.ragInstructions = ragInstructions
        self.mcpToolInstructions = mcpToolInstructions
        self.mcpToolLoopInstructions = mcpToolLoopInstructions
    }

    static func makeDefault() async throws -> ConversationModel {
        let sessionKey = MemorySessionKey(sessionID: UUID().uuidString, agentID: "ui")
        let model: GeminiModel = .gemini31FlashLite
        let fallbackDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ui", isDirectory: true)
        let databaseDirectoryURL = (try? AppDatabaseDirectory.resolve(applicationName: "ui")) ?? fallbackDirectoryURL
        let ragInstructions = try PromptResources.conversationRAGInstructions(prefixTxt: PromptResources.currentDatePrefix())
        let summarizerInstructions = try PromptResources.memorySummarizerInstructions()
        let mcpToolInstructions = try PromptResources.mcpToolInstructions()
        let mcpToolLoopInstructions = try PromptResources.mcpToolLoopInstructions()

        let budget = MemoryBudget(maxTokenCount: model.maxIdealContextTokens)
        let summarizer = GeminiMemorySummarizer(systemPrompt: summarizerInstructions)
        debugLog("Memory bootstrap started")
        debugLog("Database directory: \(databaseDirectoryURL.path)")

        do {
            let repository = try await makeMemoryStore(
                applicationName: "ui",
                databaseDirectoryURL: databaseDirectoryURL
            )
            let repositoryURL = await repository.databaseURL
            debugLog("Memory store ready: \(repositoryURL.path)")
            let memoryCoordinator = MemoryCoordinator(
                store: repository,
                summarizer: summarizer,
                policy: TieredMemoryCompactionPolicy(),
                budget: budget
            )
            let mcpBridge = try await makeLocalBridge(memoryCoordinator: memoryCoordinator, sessionKey: sessionKey)
            debugLog("MCP Bridge started")
            return ConversationModel(
                sessionKey: sessionKey,
                memoryCoordinator: memoryCoordinator,
                mcpBridge: mcpBridge,
                model: model,
                databaseDirectoryURL: await repository.databaseDirectoryURL,
                ragInstructions: ragInstructions,
                mcpToolInstructions: mcpToolInstructions,
                mcpToolLoopInstructions: mcpToolLoopInstructions
            )
        } catch {
            debugLog("Memory bootstrap failed: \(error)")
        }

        debugLog("Falling back to in-memory session store")
        let memoryCoordinator = MemoryCoordinator(
            store: InMemoryMemoryStore(),
            summarizer: summarizer,
            policy: TieredMemoryCompactionPolicy(),
            budget: budget
        )
        let mcpBridge = try await makeLocalBridge(memoryCoordinator: memoryCoordinator, sessionKey: sessionKey)
        return ConversationModel(
            sessionKey: sessionKey,
            memoryCoordinator: memoryCoordinator,
            mcpBridge: mcpBridge,
            model: model,
            databaseDirectoryURL: databaseDirectoryURL,
            ragInstructions: ragInstructions,
            mcpToolInstructions: mcpToolInstructions,
            mcpToolLoopInstructions: mcpToolLoopInstructions
        )
    }

    private static func makeLocalBridge(
        memoryCoordinator: MemoryCoordinator,
        sessionKey: MemorySessionKey
    ) async throws -> MCPLocalBridge {
        try await MCPLocalBridge.make { server in
            await server.registerSessionMemorySearchTool { arguments in
                let retrieval = try await memoryCoordinator.retrievePrior(
                    MemoryPriorRetrievalRequest(
                        sessionKey: sessionKey,
                        query: arguments.query,
                        limit: arguments.limit,
                        page: arguments.page
                    )
                )
                return retrieval.context
            }
        }
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
            mcpClient: mcpBridge.client,
            client: client,
            model: model,
            ragInstructions: ragInstructions,
            mcpToolInstructions: mcpToolInstructions,
            mcpToolLoopInstructions: mcpToolLoopInstructions,
            retrievalLimit: 5
        )

        return await pipeline.stream(prompt: prompt)
    }
}
