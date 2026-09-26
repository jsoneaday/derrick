import Foundation
import DBRepository
import MCP
import MCPClient
import MCPServer
import MemorySystem
import Plugin
import PolicyRuntime
import Structure

/// MCP effectors hosted in MCPService (`script_exec`, `web.crawl`, `web.search`, factory
/// plugin tools, and session memory). No agents_* tools.
actor MCPServiceToolHost {
    static let shared = MCPServiceToolHost()

    private var host: MCPLocalBridge?
    private var memoryCoordinator: MemoryCoordinator?

    func ensureReady() async throws -> MCPLocalBridge {
        if let host { return host }

        let repo = try await MCPServiceStore.shared.sharedRepository()
        await HostUIPresentStore.shared.configure(persister: repo)
        let budget = MemoryBudget(maxTokenCount: 200_000)
        let coordinator = MemoryCoordinator(
            store: repo,
            summarizer: DefaultMemorySummarizer(),
            policy: TieredMemoryCompactionPolicy(),
            budget: budget
        )
        memoryCoordinator = coordinator

        // Docker execution via DockerRunnerHelper peer XPC only.
        // UI prewarms the guest image. Crawler image builds in the background;
        // a crawl that arrives during that build waits on the same task.
        // Network host preflight runs in AgentService (reverse-XPC to UI) before callTool.
        await HostHTTPClient.shared.setAccessGate(BlacklistHTTPAccessGate(repository: repo))
        await HostHTTPClient.shared.setSecretAttacher(PluginDeclaredSecretAttacher())
        let factorySettings = await MainActor.run {
            LLMModelSettings(repository: repo)
        }
        await factorySettings.loadSettings()
        let factoryThinkingSettings = await MainActor.run {
            LLMModelThinkingSettings(repository: repo)
        }
        await factoryThinkingSettings.loadSettings()
        let factoryExecutor = GoPluginFactoryDockerExecutor(
            executor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor()
        )
        let webCrawlerExecutor = WebCrawlerDockerExecutor(
            executor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor()
        )
        let webSearchExecutor = WebSearchDockerExecutor(
            executor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor()
        )
        let fileExtractorExecutor = FileExtractorDockerExecutor(
            executor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor()
        )
        let factoryService = ConfiguredPluginFactoryService(
            repository: repo,
            settings: factorySettings,
            thinkingSettings: factoryThinkingSettings,
            executor: factoryExecutor,
            logger: { message in
                fputs("[MCPService] \(message)\n", stderr)
                await MCPServiceStore.shared.log(
                    level: .debug,
                    message: message,
                    code: "plugin_factory"
                )
                if let progress = WorkflowProgressPublisher.userFacingFactoryProgress(from: message) {
                    await WorkflowProgressPublisher.publish(
                        stage: WorkflowProgressPublisher.factoryStage(from: message),
                        message: progress
                    )
                }
            },
        )
        let made = try await MCPLocalBridge.make { server in
            await server.registerScriptExecutionTool(
                stdinExecutor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor(),
                reviewer: MCPServiceScriptReviewer(),
                logger: { message in
                    fputs("[MCPService] \(message)\n", stderr)
                    Task {
                        await MCPServiceStore.shared.log(level: .debug, message: message, code: "tool")
                    }
                }
            )
            await server.register(
                PluginFactoryToolModule.makeRegistration { goal, hostManifest in
                    do {
                        let release = try await factoryService.build(
                            userGoal: goal,
                            hostManifest: hostManifest
                        )
                        await MCPServiceStore.shared.log(
                            level: .info,
                            message: "plugin factory completed plugin=\(release.pluginID) version=\(release.version)",
                            code: "plugin_factory_completed"
                        )
                        return release
                    } catch {
                        let detail = pluginFactoryFailureDetail(for: error)
                        await MCPServiceStore.shared.log(
                            level: .error,
                            message: "plugin factory failed: \(detail)",
                            code: "plugin_factory_failed"
                        )
                        fputs("[MCPService] plugin factory failed: \(detail)\n", stderr)
                        throw error
                    }
                }
            )
            await server.register(
                WebCrawlerToolModule.makeRegistration { input, timeoutSeconds in
                    try await webCrawlerExecutor.run(
                        input: input,
                        timeoutSeconds: timeoutSeconds
                    )
                }
            )
            await server.register(
                WebSearchToolModule.makeRegistration { input, timeoutSeconds in
                    try await webSearchExecutor.run(
                        input: input,
                        timeoutSeconds: timeoutSeconds
                    )
                }
            )
            await server.register(
                FileExtractorToolModule.makeRegistration(
                    sessionID: { MCPServiceCallContext.shared.memorySessionKey?.sessionID },
                    run: { input, workspace, timeoutSeconds in
                        try await fileExtractorExecutor.run(
                            input: input,
                            inputDirectory: workspace.inputDirectory,
                            outputDirectory: workspace.outputDirectory,
                            timeoutSeconds: timeoutSeconds
                        )
                    }
                )
            )
            await server.register(
                PluginRuntimeToolModule.makeListRegistration(
                    list: {
                        try await repo.listPluginFactoryReleaseSummaries()
                    },
                    skillIndex: {
                        try await Self.skillIndex(from: repo)
                    }
                )
            )
            await server.register(
                PluginRuntimeToolModule.makeSkillRegistration(
                    activate: { pluginID, skill in
                        guard let summary = try await repo.listPluginFactoryReleaseSummaries()
                            .first(where: { $0.pluginID == pluginID }) else {
                            return nil
                        }
                        return try await repo.pluginSkillBody(
                            pluginID: summary.pluginID,
                            version: summary.version,
                            skill: skill
                        )
                    },
                    reference: { pluginID, path in
                        guard let summary = try await repo.listPluginFactoryReleaseSummaries()
                            .first(where: { $0.pluginID == pluginID }) else {
                            return nil
                        }
                        return try await repo.pluginSkillReference(
                            pluginID: summary.pluginID,
                            version: summary.version,
                            requested: path
                        )
                    }
                )
            )
            await server.register(
                PluginRuntimeToolModule.makeInvokeRegistration { pluginID, input in
                    guard let summary = try await repo.listPluginFactoryReleaseSummaries()
                        .first(where: { $0.pluginID == pluginID }) else {
                        return PluginFactoryExecutionResult(
                            exitCode: 1,
                            stderr: Data("No approved plugin named \(pluginID).".utf8)
                        )
                    }
                    guard let release = try await repo.pluginFactoryRelease(
                        pluginID: summary.pluginID,
                        version: summary.version
                    ) else {
                        return PluginFactoryExecutionResult(
                            exitCode: 1,
                            stderr: Data("Approved plugin release is missing.".utf8)
                        )
                    }
                    let secrets = PluginSecretField.fields(fromManifestJSON: Data(release.manifestJSON.utf8))
                    let missing = PluginSecretKeychain.missingIDs(
                        pluginID: release.pluginID,
                        fields: secrets.map(\.descriptor)
                    )
                    if !missing.isEmpty {
                        throw PluginSecretsRequiredError(
                            pluginID: release.pluginID,
                            fields: secrets
                        )
                    }
                    return try await HostHTTPInvokeSecrets.withValues(
                        pluginID: release.pluginID,
                        secretFields: secrets.map(\.descriptor)
                    ) {
                        try await GuestPluginRunner.run(
                            release: release,
                            input: input,
                            dockerExecutor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor(),
                            hopHandler: HostUIPresentHopHandler(pluginID: pluginID)
                        )
                    }
                }
            )
            await server.registerSessionMemorySearchTool { arguments in
                let sessionKey = MCPServiceCallContext.shared.memorySessionKey
                    ?? MemorySessionKey(sessionID: "mcp-service", agentID: "mcp")
                let retrieval = try await coordinator.retrievePrior(
                    MemoryPriorRetrievalRequest(
                        sessionKey: sessionKey,
                        query: arguments.query,
                        limit: arguments.limit,
                        page: arguments.page,
                        includeArchived: arguments.includeArchived
                    )
                )
                return retrieval.context
            }
        }
        host = made
        await MCPServiceStore.shared.log(
            level: .info,
            message: "MCP tool host ready (script_exec, web.crawl, web.search, files.extract)",
            code: "tool_host_ready"
        )
        return made
    }

    func searchTools(query: String, principal: ServicePrincipal) async throws -> [MCPToolDescriptorDTO] {
        let client = try await ensureReady().client
        await MCPServiceStore.shared.log(
            level: .debug,
            message: "searchTools principal=\(principal.logLabel) query=\(query.prefix(40))",
            code: "search_tools"
        )
        let tools = try await client.searchTools(matching: query)
        let mapped = tools.map {
            MCPToolDescriptorDTO(name: $0.name, description: $0.description ?? "")
        }
        return mapped
    }

    func callTool(request: MCPToolCallRequest) async throws -> MCPToolCallResultDTO {
        let client = try await ensureReady().client
        await MCPServiceStore.shared.log(
            level: .info,
            message: "callTool principal=\(request.principal.logLabel) tool=\(request.toolName)",
            code: "call_tool",
            detailJSON: #"{"requestID":"\#(request.requestID)"}"#
        )

        let toolName = request.toolName

        if toolName.hasPrefix("agents_") {
            return MCPToolCallResultDTO(
                requestID: request.requestID,
                ok: false,
                isError: true,
                text: "",
                message: "Tool \(toolName) is owned by AgentService, not MCPService."
            )
        }
        let sessionKey: MemorySessionKey
        switch request.principal {
        case .agent(let sessionID, let agentID):
            sessionKey = MemorySessionKey(sessionID: sessionID, agentID: agentID)
        default:
            sessionKey = MemorySessionKey(sessionID: "mcp-service", agentID: "mcp")
        }
        MCPServiceCallContext.shared.install(
            helperAPIKey: request.helperAPIKey,
            helperReviewerModelJSON: request.helperReviewerModelJSON,
            memorySessionKey: sessionKey,
            pluginFactoryCreationActive: request.pluginFactoryCreationActive
                || EffectorAdmissionPolicy.parseContextJSON(request.executionContextJSON)?
                    .capabilities.contains(.syncWebCrawl) == true,
            workflowID: EffectorAdmissionPolicy.parseContextJSON(request.executionContextJSON)?
                .workflow?.workflowID
        )
        let jobID: String?
        if case .job(let id) = request.principal { jobID = id } else { jobID = nil }
        HostHTTPCallContext.shared.install(jobID: jobID)
        defer {
            MCPServiceCallContext.shared.clear()
            HostHTTPCallContext.shared.clear()
        }

        // Policy decides effector/tool admission (same engine as chat). Apply allow / deny /
        // confirmHITL / redact before the tool runs.
        let policyRepo = try await MCPServiceStore.shared.sharedRepository()
        let toolPolicy = StoreBackedToolGovernancePolicy(
            store: policyRepo,
            applicationName: DerrickAppSupport.defaultApplicationName
        )
        let sessionIDForPolicy: String = {
            if case .agent(let sessionID, _) = request.principal { return sessionID }
            if case .job(let jobID) = request.principal { return jobID }
            return "mcp-service"
        }()
        var argumentsJSON = request.argumentsJSON
        let decision = try await toolPolicy.evaluateToolInvocation(
            ToolInvocationEvent(
                sessionID: sessionIDForPolicy,
                toolName: toolName,
                argumentsJSON: argumentsJSON
            )
        )
        switch decision {
        case .allow:
            break
        case .deny(let reason):
            await MCPServiceStore.shared.log(
                level: .error,
                message: "tool denied by Policy tool=\(toolName): \(reason)",
                code: "tool_denied",
                detailJSON: #"{"requestID":"\#(request.requestID)"}"#
            )
            return MCPToolCallResultDTO(
                requestID: request.requestID,
                ok: false,
                isError: true,
                text: "",
                message: reason
            )
        case .confirmHITL(let hitl):
            let approved = await awaitMCPToolHITL(
                sessionID: sessionIDForPolicy,
                toolName: toolName,
                argumentsJSON: argumentsJSON,
                hitl: hitl,
                principal: request.principal,
                repository: policyRepo
            )
            switch approved {
            case .approved(let edited, _):
                argumentsJSON = edited
            case .cancelled(let actor):
                let message = "Tool \(toolName) was not approved\(actor.map { " by \($0)" } ?? "")."
                return MCPToolCallResultDTO(
                    requestID: request.requestID,
                    ok: false,
                    isError: true,
                    text: "",
                    message: message
                )
            }
        case .redactArgument(let key, let pattern, let replacement):
            argumentsJSON = redactToolArgumentJSON(
                argumentsJSON,
                key: key,
                pattern: pattern,
                replacement: replacement
            )
        case .requireWorkflow, .redactContent:
            let message = "Tool \(toolName) returned an unsupported Policy decision."
            return MCPToolCallResultDTO(
                requestID: request.requestID,
                ok: false,
                isError: true,
                text: "",
                message: message
            )
        }

        // Shared Lib parser (same as Agent policy path) — handles repaired model JSON.
        // `{}` is a valid empty object for tools with no required args.
        let args: [String: Value]
        do {
            args = try parseToolArgumentsObject(argumentsJSON)
        } catch {
            await MCPServiceStore.shared.log(
                level: .error,
                message: "tool argument parsing failed tool=\(toolName): \(error.localizedDescription)",
                code: "tool_failed",
                detailJSON: #"{"requestID":"\#(request.requestID)"}"#
            )
            return MCPToolCallResultDTO(
                requestID: request.requestID,
                ok: false,
                isError: true,
                text: "",
                message: error.localizedDescription
            )
        }
        let result: MCPToolResult
        do {
            result = try await client.callTool(named: toolName, arguments: args)
        } catch {
            await MCPServiceStore.shared.log(
                level: .error,
                message: "tool execution failed tool=\(toolName): \(error.localizedDescription)",
                code: "tool_failed",
                detailJSON: #"{"requestID":"\#(request.requestID)"}"#
            )
            return MCPToolCallResultDTO(
                requestID: request.requestID,
                ok: false,
                isError: true,
                text: "",
                message: error.localizedDescription
            )
        }
        let isError = MCPToolOutcomeSemantics.isError(
            toolName: toolName,
            text: result.text,
            transportIsError: result.isError
        )
        let message: String
        if isError {
            message = MCPToolOutcomeSemantics.errorMessage(toolName: toolName, text: result.text)
                ?? "tool reported error"
        } else {
            message = "ok"
        }
        if isError {
            await MCPServiceStore.shared.log(
                level: .error,
                message: "tool returned an error tool=\(toolName): \(message)",
                code: "tool_failed",
                detailJSON: #"{"requestID":"\#(request.requestID)"}"#
            )
        }
        return MCPToolCallResultDTO(
            requestID: request.requestID,
            ok: true,
            isError: isError,
            text: result.text,
            message: message
        )
    }

    private func isJobPrincipal(_ principal: ServicePrincipal) -> Bool {
        if case .job = principal {
            return true
        }
        return false
    }

    private static func skillIndex(from repo: DBRepository) async throws -> [PluginSkillDisclosure.IndexEntry] {
        try await repo.listPluginSkillIndex()
    }

    private static let toolHITLPollNanoseconds: UInt64 = 1_000_000_000
    private static let toolHITLTimeoutNanoseconds: UInt64 = 15 * 60 * 1_000_000_000

    private func awaitMCPToolHITL(
        sessionID: String,
        toolName: String,
        argumentsJSON: String,
        hitl: GuardrailHITLRequest,
        principal: ServicePrincipal,
        repository: DBRepository
    ) async -> ApprovalConfirmationDecision {
        let approvalID = UUID().uuidString
        let requiredJSON = (try? JSONEncoder().encode(hitl.requiredFields))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let isJob = isJobPrincipal(principal)
        let row = PendingHITLApprovalRow(
            id: approvalID,
            turnID: sessionID,
            sessionID: sessionID,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            requiredFieldsJSON: requiredJSON,
            isJobContext: isJob
        )
        do {
            try await repository.insertPendingHITLApproval(row)
        } catch {
            fputs("[MCPService] HITL persist failed: \(error.localizedDescription)\n", stderr)
            return .cancelled(actor: "system-persist-failed")
        }
        DerrickHITLNotificationSignal.postPoll()

        let deadline = Date().addingTimeInterval(
            Double(Self.toolHITLTimeoutNanoseconds) / 1_000_000_000
        )
        while Date() < deadline {
            if Task.isCancelled {
                return .cancelled(actor: "system-cancelled")
            }
            if let decision = try? await repository.fetchPendingHITLApproval(id: approvalID),
               decision.status != .pending {
                switch decision.status {
                case .approved:
                    let args = decision.editedArgumentsJSON?.isEmpty == false
                        ? decision.editedArgumentsJSON!
                        : argumentsJSON
                    return .approved(editedArgumentsJSON: args, actor: decision.actor)
                case .cancelled, .timeout, .pending:
                    return .cancelled(actor: decision.actor ?? decision.status.rawValue)
                }
            }
            try? await Task.sleep(nanoseconds: Self.toolHITLPollNanoseconds)
        }
        try? await repository.resolveHITLApproval(
            id: approvalID,
            status: .timeout,
            editedArgumentsJSON: nil,
            actor: "system-timeout"
        )
        return .cancelled(actor: "system-timeout")
    }
}

private func redactToolArgumentJSON(
    _ json: String,
    key: String,
    pattern: String,
    replacement: String
) -> String {
    guard let data = json.data(using: .utf8),
          var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return json
    }
    if let stringValue = object[key] as? String {
        object[key] = stringValue.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )
    }
    guard let redacted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let redactedString = String(data: redacted, encoding: .utf8) else {
        return json
    }
    return redactedString
}

private func pluginFactoryFailureDetail(for error: Error) -> String {
    if let factoryError = error as? PluginFactoryError {
        return factoryError.localizedDescription
    }
    return error.localizedDescription
}
