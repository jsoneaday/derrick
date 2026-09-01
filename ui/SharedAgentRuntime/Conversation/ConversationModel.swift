import Foundation
import AgentRuntime
import DBRepository
import LLMAgentClient
import MCP
import MCPClient
import MCPServer
import MCPToolCatalog
import MemorySystem
import Plugin
import PolicyRuntime
import ServiceContracts

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
    private let repository: DBRepository
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
        helperModelSettings: LLMModelSettings,
        repository: DBRepository
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
        self.repository = repository
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
        let mcpToolInstructions = [
            try PromptResources.mcpToolInstructions(),
            try PromptResources.webCrawlerSkill(),
            try PromptResources.filesExtractSkill(),
            try PromptResources.guestSDKForModel(),
        ].joined(separator: "\n\n")

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
            helperModelSettings: helperModelSettings,
            repository: repository
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
        thinking: ModelThinkingOption? = nil,
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil,
        onChunk: @escaping @Sendable (AgentResponseNextChunk) -> Void
    ) async throws {
        if let edit = Self.pluginFactoryEditGoal(from: prompt) {
            try await runPluginFactoryEdit(
                edit,
                approvalPresenter: approvalPresenter,
                onChunk: onChunk
            )
            return
        }
        if let factoryGoal = Self.pluginFactoryGoal(from: prompt) {
            onChunk(
                AgentResponseNextChunk(
                    status: .toolCall,
                    chunk: nil,
                    toolName: AllowedMCPTool.pluginFactoryBuild.rawValue
                )
            )
            let progressTask = Self.startPluginFactoryProgress(onChunk: onChunk)
            let result: MCPToolResult
            do {
                result = try await toolClient.callTool(
                    named: AllowedMCPTool.pluginFactoryBuild.rawValue,
                    arguments: ["goal": .string(factoryGoal)]
                )
            } catch {
                progressTask.cancel()
                throw error
            }
            progressTask.cancel()
            if !result.isError,
               let pluginID = Self.pluginID(fromFactoryResult: result.text) {
                let secrets = Self.secrets(fromFactoryResult: result.text)
                let ready = await collectPluginCredentialsIfNeeded(
                    pluginID: pluginID,
                    fields: secrets,
                    mode: .requireMissing,
                    approvalPresenter: approvalPresenter
                )
                if !ready {
                    onChunk(
                        AgentResponseNextChunk(
                            status: .complete,
                            chunk: "Plugin **\(pluginID)** was saved. Add its credentials when you are ready to run it.",
                            toolName: AllowedMCPTool.pluginFactoryBuild.rawValue
                        )
                    )
                    return
                }
                onChunk(
                    AgentResponseNextChunk(
                        status: .toolCall,
                        chunk: "\n\n**Plugin approved and saved.** Running it now…\n\n",
                        toolName: AllowedMCPTool.pluginFactoryBuild.rawValue,
                        isProgress: true
                    )
                )
                onChunk(
                    AgentResponseNextChunk(
                        status: .toolCall,
                        chunk: nil,
                        toolName: AllowedMCPTool.pluginInvoke.rawValue
                    )
                )
                let runResult = try await invokePlugin(
                    pluginID: pluginID,
                    arguments: ["plugin_id": .string(pluginID)],
                    approvalPresenter: approvalPresenter
                )
                onChunk(
                    AgentResponseNextChunk(
                        status: .complete,
                        chunk: runResult.text,
                        toolName: AllowedMCPTool.pluginInvoke.rawValue
                    )
                )
                return
            }
            onChunk(
                AgentResponseNextChunk(
                    status: .complete,
                    chunk: result.text,
                    toolName: AllowedMCPTool.pluginFactoryBuild.rawValue
                )
            )
            return
        }
        if try await invokeApprovedPluginIfRequested(
            prompt: prompt,
            approvalPresenter: approvalPresenter,
            onChunk: onChunk
        ) {
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
                        thinking: thinking,
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

    private static func pluginFactoryGoal(from prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "/create-plugin"
        guard trimmed == command || trimmed.hasPrefix(command + " ") else {
            return nil
        }
        let goal = String(trimmed.dropFirst(command.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? "Help me design a useful Agent Plugin. Ask for the missing goal in the result." : goal
    }

    private struct PluginFactoryEditRequest {
        let pluginID: String
        let goal: String

        var credentialsOnly: Bool {
            let lower = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower.isEmpty
                || lower == "credentials"
                || lower == "credential"
                || lower.hasPrefix("credentials ")
        }
    }

    private static func pluginFactoryEditGoal(from prompt: String) -> PluginFactoryEditRequest? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "/edit-plugin"
        guard trimmed == command || trimmed.hasPrefix(command + " ") else {
            return nil
        }
        let remainder = String(trimmed.dropFirst(command.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return PluginFactoryEditRequest(pluginID: "", goal: "credentials")
        }
        let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let pluginID = String(parts[0])
        let goal = parts.count > 1 ? String(parts[1]) : "credentials"
        return PluginFactoryEditRequest(pluginID: pluginID, goal: goal)
    }

    private func runPluginFactoryEdit(
        _ edit: PluginFactoryEditRequest,
        approvalPresenter: (any ApprovalConfirmationPresenting)?,
        onChunk: @escaping @Sendable (AgentResponseNextChunk) -> Void
    ) async throws {
        guard !edit.pluginID.isEmpty,
              edit.pluginID != "create-plugin",
              edit.pluginID != "edit-plugin"
        else {
            onChunk(
                AgentResponseNextChunk(
                    status: .complete,
                    chunk: "Usage: `/edit-plugin <plugin-id> [goal]` or `/edit-plugin <plugin-id> credentials` to update Keychain secrets.",
                    toolName: AllowedMCPTool.pluginFactoryBuild.rawValue
                )
            )
            return
        }

        if edit.credentialsOnly {
            let secrets = await PluginCredentialCatalog.secretDescriptors(
                pluginID: edit.pluginID,
                repository: repository
            )
            guard !secrets.isEmpty else {
                onChunk(
                    AgentResponseNextChunk(
                        status: .complete,
                        chunk: "Plugin **\(edit.pluginID)** does not declare any credentials in its manifest.",
                        toolName: PluginCredentialPrompt.toolName
                    )
                )
                return
            }
            let ready = await collectPluginCredentialsIfNeeded(
                pluginID: edit.pluginID,
                fields: secrets,
                mode: .allowPartialUpdate,
                approvalPresenter: approvalPresenter
            )
            onChunk(
                AgentResponseNextChunk(
                    status: .complete,
                    chunk: ready
                        ? "Credentials for **\(edit.pluginID)** were saved to Keychain."
                        : "Credential update for **\(edit.pluginID)** was cancelled.",
                    toolName: PluginCredentialPrompt.toolName
                )
            )
            return
        }

        let factoryGoal = "Edit plugin \(edit.pluginID): \(edit.goal)"
        onChunk(
            AgentResponseNextChunk(
                status: .toolCall,
                chunk: nil,
                toolName: AllowedMCPTool.pluginFactoryBuild.rawValue
            )
        )
        let progressTask = Self.startPluginFactoryProgress(onChunk: onChunk)
        let result: MCPToolResult
        do {
            result = try await toolClient.callTool(
                named: AllowedMCPTool.pluginFactoryBuild.rawValue,
                arguments: ["goal": .string(factoryGoal)]
            )
        } catch {
            progressTask.cancel()
            throw error
        }
        progressTask.cancel()

        if !result.isError,
           let pluginID = Self.pluginID(fromFactoryResult: result.text) {
            let secrets = Self.secrets(fromFactoryResult: result.text)
            if !secrets.isEmpty {
                _ = await collectPluginCredentialsIfNeeded(
                    pluginID: pluginID,
                    fields: secrets,
                    mode: .requireMissing,
                    approvalPresenter: approvalPresenter
                )
            }
        }

        onChunk(
            AgentResponseNextChunk(
                status: .complete,
                chunk: result.text,
                toolName: AllowedMCPTool.pluginFactoryBuild.rawValue
            )
        )
    }

    private static func startPluginFactoryProgress(
        onChunk: @escaping @Sendable (AgentResponseNextChunk) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            let updates: [(UInt64, String)] = [
                (0, "**Plugin creation started.**\n\nDrafting a standalone Swift plugin…\n\n"),
                (2_000_000_000, "Running the draft test and validating its output…\n\n"),
                (15_000_000_000, "Reviewing plugin safety, correctness, and request alignment…\n\n"),
                (30_000_000_000, "Compiling the Swift source…\n\n"),
                (8_000_000_000, "Running the compiled plugin test…\n\n"),
                (8_000_000_000, "Checking terminal output and plugin integrity…\n\n"),
                (8_000_000_000, "Rechecking any correction attempt if the draft needed repair…\n\n"),
                (8_000_000_000, "Saving the approved plugin release…\n\n"),
            ]
            for (delayNanoseconds, message) in updates {
                if delayNanoseconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delayNanoseconds)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                onChunk(
                    AgentResponseNextChunk(
                        status: .toolCall,
                        chunk: message,
                        toolName: AllowedMCPTool.pluginFactoryBuild.rawValue,
                        isProgress: true
                    )
                )
            }
        }
    }

    private static func secrets(fromFactoryResult text: String) -> [PluginSecretDescriptor] {
        guard let outcome = ToolExecutionOutcome.decode(from: text),
              outcome.status == .completed,
              let value = outcome.output?.value,
              let data = value.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(PluginFactoryBuildReceipt.self, from: data) else {
            return []
        }
        return receipt.secrets ?? []
    }

    private func collectPluginCredentialsIfNeeded(
        pluginID: String,
        fields: [PluginSecretDescriptor],
        mode: PluginCredentialCollectionMode = .requireMissing,
        approvalPresenter: (any ApprovalConfirmationPresenting)?
    ) async -> Bool {
        guard !fields.isEmpty else { return true }
        if mode == .requireMissing {
            let missing = PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: fields)
            guard !missing.isEmpty else { return true }
        }
        guard let approvalPresenter else { return false }
        let payload = PluginCredentialPromptPayload(pluginID: pluginID, secrets: fields, mode: mode)
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        let decision = await approvalPresenter.confirm(
            ApprovalConfirmationRequest(
                sessionID: sessionKey.sessionID,
                toolName: PluginCredentialPrompt.toolName,
                argumentsJSON: String(decoding: data, as: UTF8.self),
                requiredFields: fields.map(\.id)
            )
        )
        switch decision {
        case .approved:
            if mode == .requireMissing {
                return PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: fields).isEmpty
            }
            return true
        case .cancelled:
            return false
        }
    }

    private func invokePlugin(
        pluginID: String,
        arguments: [String: Value],
        approvalPresenter: (any ApprovalConfirmationPresenting)?
    ) async throws -> MCPToolResult {
        var result = try await toolClient.callTool(
            named: AllowedMCPTool.pluginInvoke.rawValue,
            arguments: arguments
        )
        if let required = Self.secretsRequired(fromInvokeResult: result.text) {
            let resolvedID = required.pluginID.isEmpty ? pluginID : required.pluginID
            let allFields = await PluginCredentialCatalog.secretDescriptors(
                pluginID: resolvedID,
                repository: repository
            )
            let fields = allFields.isEmpty ? required.secrets : allFields
            let ready = await collectPluginCredentialsIfNeeded(
                pluginID: resolvedID,
                fields: fields,
                mode: .requireMissing,
                approvalPresenter: approvalPresenter
            )
            if ready {
                result = try await toolClient.callTool(
                    named: AllowedMCPTool.pluginInvoke.rawValue,
                    arguments: arguments
                )
            }
        }
        return result
    }

    private static func secretsRequired(fromInvokeResult text: String) -> PluginCredentialPromptPayload? {
        guard let outcome = ToolExecutionOutcome.decode(from: text),
              outcome.status == .blocked,
              let diagnostic = outcome.diagnostics.first(where: { $0.code == "plugin_secrets_required" }),
              let data = diagnostic.message.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(PluginCredentialPromptPayload.self, from: data)
    }
    private static func pluginID(fromFactoryResult text: String) -> String? {
        guard let outcome = ToolExecutionOutcome.decode(from: text),
              outcome.status == .completed,
              let value = outcome.output?.value,
              let data = value.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(PluginFactoryBuildReceipt.self, from: data),
              receipt.ok,
              let pluginID = receipt.pluginID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pluginID.isEmpty else {
            return nil
        }
        return pluginID
    }

    private func invokeApprovedPluginIfRequested(
        prompt: String,
        approvalPresenter: (any ApprovalConfirmationPresenting)?,
        onChunk: @escaping @Sendable (AgentResponseNextChunk) -> Void
    ) async throws -> Bool {
        guard let request = Self.pluginInvocation(from: prompt) else { return false }
        let listed = try? await toolClient.callTool(
            named: AllowedMCPTool.pluginList.rawValue,
            arguments: [:]
        )
        guard let listed,
              Self.pluginIDs(from: listed.text).contains(request.pluginID) else {
            return false
        }

        var arguments: [String: Value] = [
            "plugin_id": .string(request.pluginID),
        ]
        if !request.remainder.isEmpty {
            let input: [String: String] = ["text": request.remainder]
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            arguments["input_json"] = .string(String(decoding: data, as: UTF8.self))
        }
        onChunk(
            AgentResponseNextChunk(
                status: .toolCall,
                chunk: nil,
                toolName: AllowedMCPTool.pluginInvoke.rawValue
            )
        )
        let result = try await invokePlugin(
            pluginID: request.pluginID,
            arguments: arguments,
            approvalPresenter: approvalPresenter
        )
        onChunk(
            AgentResponseNextChunk(
                status: .complete,
                chunk: result.text,
                toolName: AllowedMCPTool.pluginInvoke.rawValue
            )
        )
        return true
    }

    private static func pluginInvocation(from prompt: String) -> (pluginID: String, remainder: String)? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return nil }
        let pluginID = String(first.dropFirst())
        guard !pluginID.isEmpty, pluginID != "create-plugin", pluginID != "edit-plugin" else {
            return nil
        }
        let remainder = parts.count == 2 ? String(parts[1]) : ""
        return (pluginID, remainder)
    }

    private static func pluginIDs(from listJSON: String) -> Set<String> {
        guard let data = listJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return Set(obj.compactMap { $0["plugin_id"] })
    }

    /// Builds the existing conversation pipeline stream for one envelope body (turn engine unchanged).
    nonisolated private static func makePolicyStream(
        prompt: String,
        apiKey: String,
        model: LLMModelChoice,
        thinking: ModelThinkingOption? = nil,
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
                thinking: thinking,
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
                thinking: thinking,
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
        let message = toolName == AllowedMCPTool.webCrawl.rawValue
            ? "Web crawl submitted. You'll get a notification banner when it finishes—tap it to view the result."
            : "Job created. You'll get a notification when it finishes—tap the notification to view the result."
        return """
        {"ok":true,"job_id":"\(job.id)","status":"\(job.status.rawValue)","run_at":"\(runAtStr)","message":"\(message)"}
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

private struct PluginFactoryBuildReceipt: Decodable {
    let ok: Bool
    let pluginID: String?
    let secrets: [PluginSecretDescriptor]?

    enum CodingKeys: String, CodingKey {
        case ok
        case pluginID = "plugin_id"
        case secrets
    }
}
