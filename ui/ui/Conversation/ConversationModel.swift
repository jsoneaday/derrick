import Foundation
import DBRepository
import LLMAgentClient
import MCPClient
import MCPServer

enum LLMProviderChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case gemini
    case openai

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var keychainAccount: String {
        switch self {
        case .gemini:
            return "gemini-api-key"
        case .openai:
            return "openai-api-key"
        }
    }

    var apiKeyEnvironmentKeys: [String] {
        switch self {
        case .gemini:
            return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .openai:
            return ["OPENAI_API_KEY"]
        }
    }

    var models: [LLMModelChoice] {
        switch self {
        case .gemini:
            return GeminiModel.allCases.map { .gemini($0) }
        case .openai:
            return OpenAIModel.allCases.map { .openai($0) }
        }
    }

    var defaultModel: LLMModelChoice {
        switch self {
        case .gemini:
            return .gemini(.gemini31FlashLite)
        case .openai:
            return .openai(.gpt5Mini)
        }
    }
}

enum LLMModelChoice: Hashable, Identifiable, Codable, Sendable {
    case gemini(GeminiModel)
    case openai(OpenAIModel)

    var id: String {
        switch self {
        case .gemini(let model):
            return "gemini:\(model.rawValue)"
        case .openai(let model):
            return "openai:\(model.rawValue)"
        }
    }

    var provider: LLMProviderChoice {
        switch self {
        case .gemini:
            return .gemini
        case .openai:
            return .openai
        }
    }

    var displayName: String {
        switch self {
        case .gemini(let model):
            return model.rawValue
        case .openai(let model):
            return model.rawValue
        }
    }

    var maxSupportedContextTokens: Int {
        switch self {
        case .gemini(let model):
            return model.maxSupportedContextTokens
        case .openai(let model):
            return model.maxSupportedContextTokens
        }
    }

    var maxIdealContextTokens: Int {
        switch self {
        case .gemini(let model):
            return model.maxIdealContextTokens
        case .openai(let model):
            return model.maxIdealContextTokens
        }
    }
}

@MainActor
final class ConversationModel {
    let sessionKey: MemorySessionKey
    let memoryCoordinator: MemoryCoordinator
    let policyStore: (any PolicyStore)?
    let mcpBridge: MCPLocalBridge
    let databaseDirectoryURL: URL
    let ragInstructions: String
    let mcpToolInstructions: String

    private init(
        sessionKey: MemorySessionKey,
        memoryCoordinator: MemoryCoordinator,
        policyStore: (any PolicyStore)?,
        mcpBridge: MCPLocalBridge,
        databaseDirectoryURL: URL,
        ragInstructions: String,
        mcpToolInstructions: String
    ) {
        self.sessionKey = sessionKey
        self.memoryCoordinator = memoryCoordinator
        self.policyStore = policyStore
        self.mcpBridge = mcpBridge
        self.databaseDirectoryURL = databaseDirectoryURL
        self.ragInstructions = ragInstructions
        self.mcpToolInstructions = mcpToolInstructions
    }

    static func makeDefault() async throws -> ConversationModel {
        let sessionKey = MemorySessionKey(sessionID: UUID().uuidString, agentID: "ui")
        let fallbackDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ui", isDirectory: true)
        let databaseDirectoryURL = (try? AppDatabaseDirectory.resolve(applicationName: "ui")) ?? fallbackDirectoryURL
        let ragInstructions = try PromptResources.conversationRAGInstructions(prefixTxt: PromptResources.currentDatePrefix())
        let summarizerInstructions = try PromptResources.memorySummarizerInstructions()
        let mcpToolInstructions = try PromptResources.mcpToolInstructions()

        let budget = MemoryBudget(maxTokenCount: 200_000)
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
                policyStore: repository,
                mcpBridge: mcpBridge,
                databaseDirectoryURL: await repository.databaseDirectoryURL,
                ragInstructions: ragInstructions,
                mcpToolInstructions: mcpToolInstructions
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
            policyStore: nil,
            mcpBridge: mcpBridge,
            databaseDirectoryURL: databaseDirectoryURL,
            ragInstructions: ragInstructions,
            mcpToolInstructions: mcpToolInstructions
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

        do {
            _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
            let schemaVersion = try await repository.currentMemorySchemaVersion(username: "ui", password: "ui")
            debugLog("Memory DB migrations completed (schema_version=\(schemaVersion)).")
        } catch {
            debugLog("Memory DB migrations failed: \(error.localizedDescription)")
            throw error
        }
        return repository
    }

    func stream(
        prompt: String,
        apiKey: String,
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil
    ) async -> AsyncThrowingStream<String, Error> {
        await stream(prompt: prompt, apiKey: apiKey, model: .gemini(.gemini31FlashLite), approvalPresenter: approvalPresenter)
    }

    func stream(
        prompt: String,
        apiKey: String,
        model: LLMModelChoice,
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil
    ) async -> AsyncThrowingStream<String, Error> {
        switch model {
        case .gemini(let geminiModel):
            let provider = GeminiProvider(apiKey: apiKey)
            let client = GeminiAgentClient(provider: provider)
            let pipeline = ConversationPipeline(
                sessionKey: sessionKey,
                memoryCoordinator: memoryCoordinator,
                policyStore: policyStore,
                applicationName: "ui",
                mcpClient: mcpBridge.client,
                client: client,
                model: geminiModel,
                ragInstructions: ragInstructions,
                mcpToolInstructions: mcpToolInstructions,
                retrievalLimit: 5
            )
            let contentInterceptor = makeContentPolicyInterceptor()
            return await pipeline.streamWithPolicyInterception(
                prompt: prompt,
                sessionID: sessionKey.sessionID,
                interceptor: contentInterceptor,
                approvalPresenter: approvalPresenter
            )
        case .openai(let openAIModel):
            let provider = OpenAIProvider(apiKey: apiKey)
            let client = OpenAIAgentClient(provider: provider)
            let pipeline = ConversationPipeline(
                sessionKey: sessionKey,
                memoryCoordinator: memoryCoordinator,
                policyStore: policyStore,
                applicationName: "ui",
                mcpClient: mcpBridge.client,
                client: client,
                model: openAIModel,
                ragInstructions: ragInstructions,
                mcpToolInstructions: mcpToolInstructions,
                retrievalLimit: 5
            )
            let contentInterceptor = makeContentPolicyInterceptor()
            return await pipeline.streamWithPolicyInterception(
                prompt: prompt,
                sessionID: sessionKey.sessionID,
                interceptor: contentInterceptor,
                approvalPresenter: approvalPresenter
            )
        }
    }

    private func makeContentPolicyInterceptor() -> PolicyInterceptor {
        guard let policyStore else {
            return DefaultPolicyInterceptor()
        }
        let policy = OnDemandCompletionContentPolicy(store: policyStore, applicationName: "ui")
        return DefaultPolicyInterceptor(policy: policy)
    }
}
