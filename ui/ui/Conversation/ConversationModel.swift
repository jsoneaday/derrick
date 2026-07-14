import Foundation
import DBRepository
import LLMAgentClient
import MCPClient
import MCPServer
import MemorySystem

enum LLMProviderChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case gemini
    case openai

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var apiKeyName: String {
        switch self {
        case .gemini:
            return "Gemini API Key"
        case .openai:
            return "OpenAI API Key"
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

    var secretAccount: String {
        "\(rawValue)-api-key"
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

    static let allCases: [LLMModelChoice] = [
        .gemini(.gemini25FlashLite),
        .gemini(.gemini31FlashLite),
        .openai(.gpt5Mini),
        .openai(.gpt54Mini),
        .openai(.gpt54),
        .openai(.gpt55)
    ]

    static let defaultHelperModel: LLMModelChoice = .gemini(.gemini25FlashLite)

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

    var helperDisplayName: String {
        "\(provider.displayName) · \(displayName)"
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

    static func makeDefault(repository: DBRepository, helperModelSettings: HelperModelSettings) async throws -> ConversationModel {
        let sessionKey = MemorySessionKey(sessionID: UUID().uuidString, agentID: "ui")
        let databaseDirectoryURL = await repository.databaseDirectoryURL
        let ragInstructions = try PromptResources.conversationRAGInstructions(prefixTxt: PromptResources.currentDatePrefix())
        let summarizerInstructions = try PromptResources.memorySummarizerInstructions()
        let mcpToolInstructions = try PromptResources.mcpToolInstructions()

        let budget = MemoryBudget(maxTokenCount: 200_000)
        let summarizer = ConfiguredMemorySummarizer(
            settings: helperModelSettings,
            systemPrompt: summarizerInstructions
        )
        debugLog("Memory bootstrap started")
        debugLog("Database directory: \(databaseDirectoryURL.path)")

        let mcpBridge = try await makeLocalBridge(
            memoryCoordinator: MemoryCoordinator(
                store: repository,
                summarizer: summarizer,
                policy: TieredMemoryCompactionPolicy(),
                budget: budget
            ),
            sessionKey: sessionKey,
            helperModelSettings: helperModelSettings
        )
        debugLog("MCP Bridge started")
        return ConversationModel(
            sessionKey: sessionKey,
            memoryCoordinator: MemoryCoordinator(
                store: repository,
                summarizer: summarizer,
                policy: TieredMemoryCompactionPolicy(),
                budget: budget
            ),
            policyStore: repository,
            mcpBridge: mcpBridge,
            databaseDirectoryURL: databaseDirectoryURL,
            ragInstructions: ragInstructions,
            mcpToolInstructions: mcpToolInstructions
        )
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
            return await pipeline.streamWithPolicyInterception(
                prompt: prompt,
                sessionID: sessionKey.sessionID,
                interceptor: makeContentPolicyInterceptor(),
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
            return await pipeline.streamWithPolicyInterception(
                prompt: prompt,
                sessionID: sessionKey.sessionID,
                interceptor: makeContentPolicyInterceptor(),
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

    private static func makeLocalBridge(
        memoryCoordinator: MemoryCoordinator,
        sessionKey: MemorySessionKey,
        helperModelSettings: HelperModelSettings
    ) async throws -> MCPLocalBridge {
        return try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(
                runner: XPCDockerRunner(),
                reviewer: ConfiguredPythonScriptReviewer(settings: helperModelSettings),
                logger: { message in debugLog(message) }
            )
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

    static func makeMemoryStore(
        applicationName: String,
        databaseDirectoryURL: URL,
        seedRules: Bool
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

        if seedRules {
            do {
                let inserted = try await seedPolicyRulesIfNeeded(repository: repository, applicationName: applicationName)
                if inserted > 0 {
                    debugLog("Policy seed inserted \(inserted) default rule(s).")
                } else {
                    debugLog("Policy seed skipped (rules already present).")
                }
            } catch {
                debugLog("Policy seed failed: \(error.localizedDescription)")
                throw error
            }
        }
        return repository
    }

    private static func seedPolicyRulesIfNeeded(repository: DBRepository, applicationName: String) async throws -> Int {
        let defaultRules: [PolicyRule] = [
            PolicyRule(
                applicationName: applicationName,
                name: "deny-shell-exec",
                scope: "tool_invocation",
                matcherJSON: #"{"tool_name":"shell_exec"}"#,
                outcomeJSON: #"{"action":"deny","reason":"shell_exec is blocked by default testing policy."}"#,
                priority: 1000
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "confirm-write-tools",
                scope: "tool_invocation",
                matcherJSON: #"{"tool_name_contains":"write"}"#,
                outcomeJSON: #"{"action":"confirm","required_fields":["change_ticket","justification"]}"#,
                priority: 900
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "redact-api-key-chunks",
                scope: "assistant_chunk",
                matcherJSON: #"{"content_pattern":"(?i)api[_ -]?key\s*[:=]\s*\S+"}"#,
                outcomeJSON: #"{"action":"redact","pattern":"(?i)api[_ -]?key\s*[:=]\s*\S+","replacement":"api_key: [REDACTED]"}"#,
                priority: 850
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "confirm-email-completions",
                scope: "assistant_completion_content",
                matcherJSON: #"{"detected_patterns_any":["email"]}"#,
                outcomeJSON: #"{"action":"confirm","required_fields":["privacy_review"]}"#,
                priority: 800
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "deny-ssn-completions",
                scope: "assistant_completion_content",
                matcherJSON: #"{"detected_patterns_any":["ssn"]}"#,
                outcomeJSON: #"{"action":"deny","reason":"SSN-like patterns are blocked."}"#,
                priority: 950
            )
        ]

        var inserted = 0
        for rule in defaultRules {
            let existing = try await repository.loadRules(applicationName: applicationName, scope: rule.scope)
            guard existing.contains(where: { $0.name == rule.name }) == false else {
                continue
            }
            try await repository.saveRule(rule)
            inserted += 1
        }

        return inserted
    }
}
