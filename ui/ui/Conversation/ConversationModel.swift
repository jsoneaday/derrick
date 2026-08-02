import Foundation
import AgentRuntime
import DBRepository
import LLMAgentClient
import MCPClient
import MCPServer
import MCPToolCatalog
import MemorySystem
import PolicyRuntime

@MainActor
final class ConversationModel {
    let sessionKey: MemorySessionKey
    let orchestrator: SessionOrchestrator
    let memoryCoordinator: MemoryCoordinator
    let policyStore: (any PolicyStore)?
    let mcpBridge: MCPLocalBridge
    let databaseDirectoryURL: URL
    let ragInstructions: String
    let mcpToolInstructions: String
    let responseSchema: AgentSchema = AgentSchema(
        type: .object,
        properties: [
            "status": AgentSchema(type: .string, description: "One of: '\(AgentResponseStatus.thinking.rawValue)', '\(AgentResponseStatus.toolCall.rawValue)', '\(AgentResponseStatus.toolBatch.rawValue)', '\(AgentResponseStatus.complete.rawValue)'. CacheBust: \(UUID().uuidString)"),
            "thought": AgentSchema(type: .string, description: "Your internal plan or reasoning steps"),
            "assistant_response": AgentSchema(type: .string, description: "The markdown, json or csv message content meant for user."),
            "tool_call": AgentSchema(
                type: .object,
                properties: [
                    "tool_name": AgentSchema(type: .string, description: "Name of the tool to execute"),
                    "arguments": AgentSchema(type: .string, description: "JSON-formatted string of tool arguments")
                ],
                required: ["tool_name", "arguments"]
            ),
            "tool_batch": AgentSchema(
                type: .object,
                properties: [
                    "invocations": AgentSchema(
                        type: .array,
                        items: AgentSchema(
                            type: .object,
                            properties: [
                                "tool_name": AgentSchema(type: .string, description: "Name of the tool to execute"),
                                "arguments": AgentSchema(type: .string, description: "JSON-formatted string of tool arguments")
                            ],
                            required: ["tool_name", "arguments"]
                        ),
                        description: "Array of tool invocation objects"
                    ),
               ],
               required: ["invocations"]
            )
        ],
        required: ["status"],
    )

    private init(
        sessionKey: MemorySessionKey,
        orchestrator: SessionOrchestrator,
        memoryCoordinator: MemoryCoordinator,
        policyStore: (any PolicyStore)?,
        mcpBridge: MCPLocalBridge,
        databaseDirectoryURL: URL,
        ragInstructions: String,
        mcpToolInstructions: String
    ) {
        self.sessionKey = sessionKey
        self.orchestrator = orchestrator
        self.memoryCoordinator = memoryCoordinator
        self.policyStore = policyStore
        self.mcpBridge = mcpBridge
        self.databaseDirectoryURL = databaseDirectoryURL
        self.ragInstructions = ragInstructions
        self.mcpToolInstructions = mcpToolInstructions
    }

    static func makeDefault(repository: DBRepository, helperModelSettings: LLMModelSettings) async throws -> ConversationModel {
        let sessionID = UUID().uuidString
        let orchestrator = SessionOrchestrator(sessionID: sessionID)
        try await orchestrator.bootstrapUserFacingAgent()
        let sessionKey = orchestrator.memorySessionKey
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
            orchestrator: orchestrator,
            helperModelSettings: helperModelSettings
        )
        debugLog("MCP Bridge started")
        return ConversationModel(
            sessionKey: sessionKey,
            orchestrator: orchestrator,
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
    ) async -> AsyncThrowingStream<AgentResponseNextChunk, Error> {
        let sessionKey = self.sessionKey
        let memoryCoordinator = self.memoryCoordinator
        let policyStore = self.policyStore
        let mcpClient = self.mcpBridge.client
        let ragInstructions = self.ragInstructions
        let mcpToolInstructions = self.mcpToolInstructions
        let responseSchema = self.responseSchema
        let interceptor = makeContentPolicyInterceptor()
        let orchestrator = self.orchestrator

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let workerRunner: @Sendable (AgentRecord, AgentEnvelope) async throws -> String = { child, envelope in
                        // Caller identity is set by HierarchicalOrchestrator via AgentCallContext (task-local).
                        let childKey = MemorySessionKey(agentRef: child.ref)
                        let overlay = child.systemOverlay ?? WorkerOverlays.workerDefault
                        let rag = [ragInstructions, overlay].joined(separator: "\n\n")
                        // Workers: use pipeline but do not yield to user UI.
                        let stream = await Self.makePolicyStream(
                            prompt: envelope.body,
                            apiKey: apiKey,
                            model: model,
                            sessionKey: childKey,
                            memoryCoordinator: memoryCoordinator,
                            policyStore: policyStore,
                            mcpClient: mcpClient,
                            ragInstructions: rag,
                            mcpToolInstructions: mcpToolInstructions,
                            responseSchema: responseSchema,
                            interceptor: interceptor,
                            approvalPresenter: nil
                        )
                        var completeText = ""
                        for try await chunk in stream {
                            if chunk.status == .complete {
                                completeText += chunk.chunk ?? ""
                            }
                        }
                        return completeText
                    }

                    try await orchestrator.withWorkerRunner(workerRunner) {
                        try await orchestrator.deliverUserMessage(prompt) { envelope in
                            try await AgentCallContext.$caller.withValue(orchestrator.userFacingRef) {
                                let userRag = [ragInstructions, WorkerOverlays.userFacingWithSpawn].joined(separator: "\n\n")
                                let pipelineStream = await Self.makePolicyStream(
                                    prompt: envelope.body,
                                    apiKey: apiKey,
                                    model: model,
                                    sessionKey: sessionKey,
                                    memoryCoordinator: memoryCoordinator,
                                    policyStore: policyStore,
                                    mcpClient: mcpClient,
                                    ragInstructions: userRag,
                                    mcpToolInstructions: mcpToolInstructions,
                                    responseSchema: responseSchema,
                                    interceptor: interceptor,
                                    approvalPresenter: approvalPresenter
                                )
                                for try await chunk in pipelineStream {
                                    continuation.yield(chunk)
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    debugLog("AgentRuntime turn failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Builds the existing conversation pipeline stream for one envelope body (turn engine unchanged).
    nonisolated private static func makePolicyStream(
        prompt: String,
        apiKey: String,
        model: LLMModelChoice,
        sessionKey: MemorySessionKey,
        memoryCoordinator: MemoryCoordinator,
        policyStore: (any PolicyStore)?,
        mcpClient: MCPClient,
        ragInstructions: String,
        mcpToolInstructions: String,
        responseSchema: AgentSchema,
        interceptor: PolicyInterceptor,
        approvalPresenter: (any ApprovalConfirmationPresenting)?
    ) async -> AsyncThrowingStream<AgentResponseNextChunk, Error> {
        switch model {
        case .gemini(let geminiModel):
            let provider = GeminiProvider(apiKey: apiKey)
            let client = GeminiAgentClient(provider: provider)
            let pipeline = ConversationPipeline(
                sessionKey: sessionKey,
                memoryCoordinator: memoryCoordinator,
                policyStore: policyStore,
                applicationName: "ui",
                mcpClient: mcpClient,
                client: client,
                model: geminiModel,
                ragInstructions: ragInstructions,
                mcpToolInstructions: mcpToolInstructions,
                retrievalLimit: 5
            )
            return await pipeline.streamWithPolicyInterception(
                prompt: prompt,
                sessionID: sessionKey.sessionID,
                interceptor: interceptor,
                approvalPresenter: approvalPresenter,
                responseSchema: responseSchema
            )
        case .openai(let openAIModel):
            let provider = OpenAIProvider(apiKey: apiKey)
            let client = OpenAIAgentClient(provider: provider)
            let pipeline = ConversationPipeline(
                sessionKey: sessionKey,
                memoryCoordinator: memoryCoordinator,
                policyStore: policyStore,
                applicationName: "ui",
                mcpClient: mcpClient,
                client: client,
                model: openAIModel,
                ragInstructions: ragInstructions,
                mcpToolInstructions: mcpToolInstructions,
                retrievalLimit: 5
            )
            return await pipeline.streamWithPolicyInterception(
                prompt: prompt,
                sessionID: sessionKey.sessionID,
                interceptor: interceptor,
                approvalPresenter: approvalPresenter
            )
        }
    }

    private func makeContentPolicyInterceptor() -> PolicyInterceptor {
        guard let policyStore else {
            return DefaultPolicyInterceptor()
        }
        let policy = StoreBackedCompletionContentPolicy(store: policyStore, applicationName: "ui")
        return DefaultPolicyInterceptor(policy: policy)
    }

    private static func makeLocalBridge(
        memoryCoordinator: MemoryCoordinator,
        sessionKey: MemorySessionKey,
        orchestrator: SessionOrchestrator,
        helperModelSettings: LLMModelSettings
    ) async throws -> MCPLocalBridge {
        return try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(
                runner: XPCDockerRunner.shared,
                reviewer: ConfiguredPythonScriptReviewer(settings: helperModelSettings),
                networkPreflight: { script, allowNetwork in
                    await EgressAllowlistService.shared.preflightPythonScriptNetwork(
                        script: script,
                        allowNetwork: allowNetwork
                    )
                },
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
            await server.register(
                AgentOrchestrationToolModule.spawnRegistration { goal, task, agentID in
                    try await orchestrator.spawnWorker(goal: goal, task: task, agentID: agentID)
                }
            )
            await server.register(
                AgentOrchestrationToolModule.completeTaskRegistration { result, agentID in
                    try await orchestrator.completeTask(result: result, agentID: agentID)
                }
            )
            await server.register(
                AgentOrchestrationToolModule.listRegistration { childrenOnly in
                    try await orchestrator.listAgents(childrenOnly: childrenOnly)
                }
            )
            await server.register(
                AgentOrchestrationToolModule.sendRegistration { toAgentID, message in
                    try await orchestrator.send(toAgentID: toAgentID, message: message)
                }
            )
            await server.register(
                AgentOrchestrationToolModule.cancelRegistration { agentID in
                    try await orchestrator.cancel(agentID: agentID)
                }
            )
        }
    }

    /// Opens the app DB and always seeds baseline policy rules when missing.
    /// Seeding is not debug-only: empty rule tables fail closed at evaluation time.
    static func makeMemoryStore(
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
                name: "confirm-phone-completions",
                scope: "assistant_completion_content",
                matcherJSON: #"{"detected_patterns_any":["phone"]}"#,
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
            ),
            // Explicit allows for each catalog MCP tool (deny-by-default; no catch-all).
        ] + AllowedMCPTool.allCases.map { tool in
            PolicyRule(
                applicationName: applicationName,
                name: "allow-\(tool.rawValue)",
                scope: "tool_invocation",
                matcherJSON: #"{"tool_name":"\#(tool.rawValue)"}"#,
                outcomeJSON: #"{"action":"allow"}"#,
                priority: 1
            )
        } + [
            PolicyRule(
                applicationName: applicationName,
                name: "allow-default-assistant-chunks",
                scope: "assistant_chunk",
                matcherJSON: #"{}"#,
                outcomeJSON: #"{"action":"allow"}"#,
                priority: 1
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "allow-default-assistant-completions",
                scope: "assistant_completion_content",
                matcherJSON: #"{}"#,
                outcomeJSON: #"{"action":"allow"}"#,
                priority: 1
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
