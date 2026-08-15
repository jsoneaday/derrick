import Foundation
import AgentRuntime
import DBRepository
import LLMAgentClient
import MCP
import MCPClient
import MCPServer
import MCPToolCatalog
import MemorySystem
import PolicyRuntime
import ServiceContracts
import Plugin

@MainActor
final class ConversationModel {
    let sessionKey: MemorySessionKey
    let orchestrator: SessionOrchestrator
    let memoryCoordinator: MemoryCoordinator
    let policyStore: (any PolicyStore)?
    /// Local orchestration tools only (`agents_*`). Effectors never run here — MCPService XPC.
    private let agentsOrchestrationHost: MCPLocalBridge
    let toolClient: any ConversationToolClient
    let ragInstructions: String
    let mcpToolInstructions: String
    private let helperModelSettings: LLMModelSettings
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
                    "arguments": AgentSchema(
                        type: .string,
                        description: "Single-line JSON object string of tool arguments. Escape newlines as \\n and quotes as \\\". Keep compact; nested scripts must use \\n not real line breaks."
                    )
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
                                "arguments": AgentSchema(
                                    type: .string,
                                    description: "Single-line JSON object string of tool arguments. Escape newlines as \\n and quotes as \\\"."
                                )
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
        agentsOrchestrationHost: MCPLocalBridge,
        toolClient: any ConversationToolClient,
        ragInstructions: String,
        mcpToolInstructions: String,
        helperModelSettings: LLMModelSettings
    ) {
        self.sessionKey = sessionKey
        self.orchestrator = orchestrator
        self.memoryCoordinator = memoryCoordinator
        self.policyStore = policyStore
        self.agentsOrchestrationHost = agentsOrchestrationHost
        self.toolClient = toolClient
        self.ragInstructions = ragInstructions
        self.mcpToolInstructions = mcpToolInstructions
        self.helperModelSettings = helperModelSettings
    }

    static func makeDefault(
        repository: DBRepository,
        helperModelSettings: LLMModelSettings,
        sessionID: String? = nil,
        agentIDOverride: String? = nil
    ) async throws -> ConversationModel {
        let sessionID = sessionID ?? UUID().uuidString
        let orchestrator = try await SessionOrchestrator.make(
            sessionID: sessionID,
            repository: repository
        )
        try await orchestrator.bootstrapUserFacingAgent()
        var sessionKey = orchestrator.memorySessionKey
        if let agentIDOverride {
            sessionKey = MemorySessionKey(sessionID: sessionKey.sessionID, agentID: agentIDOverride)
        }
        let ragInstructions = try PromptResources.conversationRAGInstructions(prefixTxt: PromptResources.currentDatePrefix())
        let summarizerInstructions = try PromptResources.memorySummarizerInstructions()
        var mcpToolInstructions = [
            try PromptResources.mcpToolInstructions(),
            PluginEnvelopeSchema.ragSection,
        ].joined(separator: "\n\n")
        if await factoryEnabled(repository: repository),
           FactorySessionID.isFactorySession(sessionID) {
            mcpToolInstructions += "\n\n" + (try PromptResources.softwareFactoryInstructions())
        } else if await factoryEnabled(repository: repository) {
            mcpToolInstructions += """


            Software Factory is on. To build a plugin, the user opens Software Factory from the sidebar. In this chat, use plugin.invoke / plugin.list for installed plugins, or the user can type /plugin-id to run one.
            """
        }

        let budget = MemoryBudget(maxTokenCount: 200_000)
        let summarizer = ConfiguredMemorySummarizer(
            settings: helperModelSettings,
            systemPrompt: summarizerInstructions
        )
        debugLog("Memory bootstrap started session=\(sessionKey.sessionID) agent=\(sessionKey.agentID)")
        debugLog("Database directory: \(await repository.databaseDirectoryURL.path)")

        let agentsHost = try await makeAgentsOrchestrationHost(
            orchestrator: orchestrator,
            sessionID: sessionKey.sessionID,
            agentID: sessionKey.agentID,
            helperModelSettings: helperModelSettings
        )
        let principal = ServicePrincipal.agent(
            sessionID: sessionKey.sessionID,
            agentID: sessionKey.agentID
        )
        let toolClient = XPCConversationToolClient(
            principal: principal,
            agentsClient: agentsHost.client,
            helperReviewerModelJSONProvider: {
                await MainActor.run {
                    try? helperModelSettings.scriptReviewerModel.encodeHelperModelWireJSON()
                }
            }
        )
        debugLog(
            "Tools: agents_* + jobs_* local host; effectors → MCPService XPC (principal=\(principal.logLabel))"
        )
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
            agentsOrchestrationHost: agentsHost,
            toolClient: toolClient,
            ragInstructions: ragInstructions,
            mcpToolInstructions: mcpToolInstructions,
            helperModelSettings: helperModelSettings
        )
    }

    func stream(
        prompt: String,
        apiKey: String,
        model: LLMModelChoice,
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil
    ) async -> AsyncThrowingStream<AgentResponseNextChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.runTurn(
                        prompt: prompt,
                        apiKey: apiKey,
                        model: model,
                        approvalPresenter: approvalPresenter
                    ) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    debugLog("AgentRuntime turn failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                // Only cancel in-flight work on client cancel — not on normal finish
                // (cancelling on .finished races nested pipeline streams → 0 chunks).
                if case .cancelled = reason {
                    task.cancel()
                }
            }
        }
    }

    /// Runs one user-facing turn and delivers chunks via callback (preferred for XPC hosting).
    func runTurn(
        prompt: String,
        apiKey: String,
        model: LLMModelChoice,
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil,
        onChunk: @escaping @Sendable (AgentResponseNextChunk) -> Void
    ) async throws {
        if try await tryPrefixInvoke(prompt: prompt, onChunk: onChunk) {
            return
        }
        let sessionKey = self.sessionKey
        let memoryCoordinator = self.memoryCoordinator
        let policyStore = self.policyStore
        let toolClient = self.toolClient
        let ragInstructions = self.ragInstructions
        let mcpToolInstructions = self.mcpToolInstructions
        let responseSchema = self.responseSchema
        let interceptor = makeContentPolicyInterceptor()
        let orchestrator = self.orchestrator
        let workerModel = helperModelSettings.workerAgentModel
        let workerApiKey = resolveAPIKey(for: workerModel, turnFallback: apiKey) ?? apiKey

        let workerRunner: @Sendable (AgentRecord, AgentEnvelope) async throws -> String = { child, envelope in
            try await ExecutionContextScope.runWorkerTurn(agentRef: child.ref) {
                let childKey = MemorySessionKey(agentRef: child.ref)
                let overlay = child.systemOverlay ?? WorkerOverlays.workerDefault
                let rag = [ragInstructions, overlay].joined(separator: "\n\n")
                let stream = await Self.makePolicyStream(
                    prompt: envelope.body,
                    apiKey: workerApiKey,
                    model: workerModel,
                    sessionKey: childKey,
                    memoryCoordinator: memoryCoordinator,
                    policyStore: policyStore,
                    mcpClient: toolClient,
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
                        mcpClient: toolClient,
                        ragInstructions: userRag,
                        mcpToolInstructions: mcpToolInstructions,
                        responseSchema: responseSchema,
                        interceptor: interceptor,
                        approvalPresenter: approvalPresenter
                    )
                    var yielded = 0
                    for try await chunk in pipelineStream {
                        yielded += 1
                        onChunk(chunk)
                    }
                    debugLog("AgentRuntime user-facing pipeline finished yields=\(yielded)")
                    if yielded == 0 {
                        debugLog("AgentRuntime warning: pipeline produced 0 chunks for prompt chars=\(prompt.count)")
                    }
                }
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
        mcpClient: any ConversationToolClient,
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
                approvalPresenter: approvalPresenter,
                responseSchema: responseSchema
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

    /// API key for a helper/worker model: keychain/env for its provider, else the active turn key.
    private func resolveAPIKey(for model: LLMModelChoice, turnFallback: String) -> String? {
        if let key = AppSecretResolver().resolve(
            account: model.provider.secretAccount,
            environmentKeys: model.provider.apiKeyEnvironmentKeys
        ), !key.isEmpty {
            return key
        }
        if let turnKey = TurnProcessContext.effectiveAPIKey, !turnKey.isEmpty {
            return turnKey
        }
        let trimmed = turnFallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// In-process host for orchestration tools (`agents_*`, `jobs_*`). Not used for MCP effectors.
    /// `nonisolated`: tool handlers must not hop to MainActor while the turn awaits the MCP local bridge
    /// (that pattern deadlocks when runTurn is MainActor-isolated).
    nonisolated private static func makeAgentsOrchestrationHost(
        orchestrator: SessionOrchestrator,
        sessionID: String,
        agentID: String,
        helperModelSettings: LLMModelSettings
    ) async throws -> MCPLocalBridge {
        let principal = ServicePrincipal.agent(sessionID: sessionID, agentID: agentID)
        let placer: any JobOrderPlacing = JobServiceClientOrderPlacer(from: .agent)
        // Snapshot reviewer wire JSON once at host build — never read MainActor settings inside a tool call.
        let reviewerJSON: String? = await MainActor.run {
            try? helperModelSettings.scriptReviewerModel.encodeHelperModelWireJSON()
        }
        return try await MCPLocalBridge.make { server in
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
            await server.register(
                JobOrchestrationToolModule.createJobRegistration {
                    runAfterSeconds, runAtString, toolName, toolArgumentsJSON, wakeAfter, wakePrompt, description
                in
                    try await placeJobCreate(
                        placer: placer,
                        principal: principal,
                        sessionID: sessionID,
                        agentID: agentID,
                        reviewerJSON: reviewerJSON,
                        runAfterSeconds: runAfterSeconds,
                        runAtString: runAtString,
                        toolName: toolName,
                        toolArgumentsJSON: toolArgumentsJSON,
                        wakeAfter: wakeAfter,
                        wakePrompt: wakePrompt,
                        description: description
                    )
                }
            )
            await server.register(
                JobOrchestrationToolModule.createScheduleRegistration {
                    name, recurrence, intervalSeconds, runAfterSeconds, nextFireAt, toolName, toolArgumentsJSON,
                        wakeAfter, wakePrompt
                in
                    try await placeScheduleCreate(
                        placer: placer,
                        principal: principal,
                        sessionID: sessionID,
                        agentID: agentID,
                        reviewerJSON: reviewerJSON,
                        name: name,
                        recurrence: recurrence,
                        intervalSeconds: intervalSeconds,
                        runAfterSeconds: runAfterSeconds,
                        nextFireAtString: nextFireAt,
                        toolName: toolName,
                        toolArgumentsJSON: toolArgumentsJSON,
                        wakeAfter: wakeAfter,
                        wakePrompt: wakePrompt
                    )
                }
            )
        }
    }

    nonisolated private static func placeJobCreate(
        placer: any JobOrderPlacing,
        principal: ServicePrincipal,
        sessionID: String,
        agentID: String,
        reviewerJSON: String?,
        runAfterSeconds: Int?,
        runAtString: String?,
        toolName: String,
        toolArgumentsJSON: String,
        wakeAfter: Bool,
        wakePrompt: String?,
        description: String?
    ) async throws -> String {
        debugLog("[jobs_create] begin tool=\(toolName) run_after=\(runAfterSeconds.map(String.init) ?? "nil")")
        let runAt = runAtString.flatMap { JobOrderBuilder.parseRunAtString($0) }
        let input = JobCreateOrderInput(
            runAfterSeconds: runAfterSeconds,
            runAt: runAt,
            toolName: toolName,
            toolArgumentsJSON: toolArgumentsJSON,
            wakeAfter: wakeAfter,
            wakePrompt: wakePrompt,
            description: description
        )
        let request = try JobOrderBuilder.createJobRequest(
            from: input,
            principal: principal,
            source: .agent,
            sessionID: sessionID,
            agentID: agentID,
            helperAPIKey: TurnProcessContext.effectiveAPIKey,
            helperReviewerModelJSON: reviewerJSON
        )
        debugLog("[jobs_create] calling JobService createJob…")
        let job = try await placer.createJob(request)
        debugLog("[jobs_create] ok id=\(job.id) status=\(job.status.rawValue)")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let runAtStr = job.runAt.map { iso.string(from: $0) } ?? "asap"
        return """
        {"ok":true,"job_id":"\(job.id)","status":"\(job.status.rawValue)","run_at":"\(runAtStr)","message":"Job created. You'll get a notification when it finishes—tap the notification to view the result."}
        """
    }

    nonisolated private static func placeScheduleCreate(
        placer: any JobOrderPlacing,
        principal: ServicePrincipal,
        sessionID: String,
        agentID: String,
        reviewerJSON: String?,
        name: String,
        recurrence: String,
        intervalSeconds: Int?,
        runAfterSeconds: Int?,
        nextFireAtString: String?,
        toolName: String,
        toolArgumentsJSON: String,
        wakeAfter: Bool,
        wakePrompt: String?
    ) async throws -> String {
        debugLog("[jobs_schedule_create] begin name=\(name) recurrence=\(recurrence)")
        let kind: JobRecurrenceKind
        switch recurrence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "interval": kind = .interval
        case "once", "": kind = .once
        default:
            throw JobOrderBuilderError.invalidRecurrence
        }
        let nextFire = nextFireAtString.flatMap { JobOrderBuilder.parseRunAtString($0) }
        let input = JobScheduleOrderInput(
            name: name,
            recurrenceKind: kind,
            intervalSeconds: intervalSeconds,
            runAfterSeconds: runAfterSeconds,
            nextFireAt: nextFire,
            toolName: toolName,
            toolArgumentsJSON: toolArgumentsJSON,
            wakeAfter: wakeAfter,
            wakePrompt: wakePrompt,
            enabled: true
        )
        let request = try JobOrderBuilder.createScheduleRequest(
            from: input,
            principal: principal,
            source: .agent,
            sessionID: sessionID,
            agentID: agentID,
            helperAPIKey: TurnProcessContext.effectiveAPIKey,
            helperReviewerModelJSON: reviewerJSON
        )
        let schedule = try await placer.createSchedule(request)
        debugLog("[jobs_schedule_create] ok id=\(schedule.id)")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let next = schedule.nextFireAt.map { iso.string(from: $0) } ?? "asap"
        return """
        {"ok":true,"schedule_id":"\(schedule.id)","name":"\(schedule.name)","recurrence":"\(schedule.recurrence.kind.rawValue)","next_fire_at":"\(next)","enabled":\(schedule.enabled),"message":"Schedule created."}
        """
    }

    /// `/plugin-id rest` skips the LLM when exactly one installed plugin matches.
    private func tryPrefixInvoke(
        prompt: String,
        onChunk: @escaping @Sendable (AgentResponseNextChunk) -> Void
    ) async throws -> Bool {
        guard let parsed = PluginPrefix.parse(prompt) else { return false }
        let listed: MCPToolResult
        do {
            listed = try await toolClient.callTool(named: AllowedMCPTool.pluginList.rawValue, arguments: [:])
        } catch {
            return false
        }
        let ids = pluginIDs(from: listed.text)
        guard let pluginID = PluginPrefix.uniqueMatch(handle: parsed.handle, pluginIDs: ids) else {
            return false
        }
        var arguments: [String: Value] = [
            "plugin_id": .string(pluginID),
            "kind": .string(PluginEventKind.messageInRoom.rawValue),
        ]
        if !parsed.remainder.isEmpty {
            arguments["params"] = .object(["text": .string(parsed.remainder)])
        }
        onChunk(
            AgentResponseNextChunk(
                status: .toolCall,
                chunk: nil,
                toolName: AllowedMCPTool.pluginInvoke.rawValue
            )
        )
        let result = try await toolClient.callTool(
            named: AllowedMCPTool.pluginInvoke.rawValue,
            arguments: arguments
        )
        let body = PluginInvokePresentation.userFacingText(fromScriptResult: result.text)
        let chunk: String
        if PluginInvokePresentation.isProgrammatic(body) {
            chunk = PluginInvokePresentation.encodeTestReport(
                PluginInvokePresentation.TestReport(
                    heading: "/\(pluginID)",
                    body: body,
                    kind: .programmatic
                )
            )
        } else {
            chunk = body
        }
        onChunk(
            AgentResponseNextChunk(
                status: .complete,
                chunk: chunk,
                toolName: AllowedMCPTool.pluginInvoke.rawValue
            )
        )
        return true
    }

    private func pluginIDs(from listJSON: String) -> [String] {
        guard let data = listJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["plugins"] as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            let enabled = row["enabled"] as? Bool ?? true
            guard enabled else { return nil }
            return (row["plugin_id"] as? String) ?? (row["id"] as? String)
        }
    }

    private static func factoryEnabled(repository: DBRepository) async -> Bool {
        guard let raw = try? await repository.loadConfig(
            key: SoftwareFactorySettings.configKey,
            username: "ui",
            password: "ui"
        ),
              let data = raw.data(using: .utf8),
              let settings = try? JSONDecoder().decode(SoftwareFactorySettings.self, from: data) else {
            return false
        }
        return settings.enabled
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
        } + ["tool_search", "tool", "tool_batch"].map { name in
            PolicyRule(
                applicationName: applicationName,
                name: "allow-\(name)",
                scope: "tool_invocation",
                matcherJSON: #"{"tool_name":"\#(name)"}"#,
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
