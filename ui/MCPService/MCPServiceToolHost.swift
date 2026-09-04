import Foundation
import DBRepository
import Lib
import MCP
import MCPClient
import MCPServer
import MCPToolCatalog
import MemorySystem
import Plugin
import ServiceContracts

/// MCP effectors hosted in MCPService (`script_exec`, `web.crawl`, factory
/// plugin tools, and session memory). No agents_* tools.
actor MCPServiceToolHost {
    static let shared = MCPServiceToolHost()

    private var host: MCPLocalBridge?
    private var memoryCoordinator: MemoryCoordinator?

    func ensureReady() async throws -> MCPLocalBridge {
        if let host { return host }

        let repo = try await MCPServiceStore.shared.sharedRepository()
        let budget = MemoryBudget(maxTokenCount: 200_000)
        let coordinator = MemoryCoordinator(
            store: repo,
            summarizer: DefaultMemorySummarizer(),
            policy: TieredMemoryCompactionPolicy(),
            budget: budget
        )
        memoryCoordinator = coordinator

        // Swift Docker execution via DockerRunnerHelper peer XPC only.
        // UI prewarms containers and hands the helper peer endpoint at bootstrap.
        // Network host preflight runs in AgentService (reverse-XPC to UI) before callTool.
        await HostHTTPClient.shared.setAccessGate(BlacklistHTTPAccessGate(repository: repo))
        await HostHTTPClient.shared.setSecretAttacher(PluginDeclaredSecretAttacher())
        let factorySettings = await MainActor.run {
            LLMModelSettings(repository: repo)
        }
        await factorySettings.loadSettings()
        let factoryExecutor = PythonPluginFactoryDockerExecutor(
            executor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor()
        )
        let webCrawlerExecutor = WebCrawlerDockerExecutor(
            executor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor()
        )
        let fileExtractorExecutor = FileExtractorDockerExecutor(
            executor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor()
        )
        let factoryService = ConfiguredPluginFactoryService(
            repository: repo,
            settings: factorySettings,
            executor: factoryExecutor,
            logger: { message in
                fputs("[MCPService] \(message)\n", stderr)
                await MCPServiceStore.shared.log(
                    level: .debug,
                    message: message,
                    code: "plugin_factory"
                )
                if let progress = WorkflowProgressPublisher.userFacingFactoryProgress(from: message) {
                    await WorkflowProgressPublisher.publish(stage: "factory", message: progress)
                }
            },
            apiKeyProvider: {
                MCPServiceCallContext.shared.helperAPIKey
                    ?? TurnProcessContext.effectiveAPIKey
            }
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
                PluginFactoryToolModule.makeRegistration { goal in
                    do {
                        let release = try await factoryService.build(userGoal: goal)
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
                PluginRuntimeToolModule.makeListRegistration {
                    try await repo.listPluginFactoryReleaseSummaries()
                }
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
                    HostHTTPCallContext.shared.setPluginSecrets(
                        pluginID: release.pluginID,
                        fields: secrets.map(\.descriptor)
                    )
                    defer {
                        HostHTTPCallContext.shared.setPluginSecrets(pluginID: "", fields: [])
                    }
                    return try await GuestPluginRunner.run(
                        release: release,
                        input: input,
                        dockerExecutor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor()
                    )
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
            message: "MCP tool host ready (script_exec, web.crawl, files.extract)",
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
        if toolName == AllowedMCPTool.webCrawl.rawValue,
           !EffectorAdmissionPolicy.allowsSyncWebCrawl(
               context: EffectorAdmissionPolicy.parseContextJSON(request.executionContextJSON)
                   ?? legacyExecutionContext(from: request),
               principal: request.principal
           ) {
            let outcome = ToolExecutionOutcome.failure(
                status: .blocked,
                stage: .validation,
                diagnostics: [
                    ToolExecutionOutcome.Diagnostic(
                        code: "web_crawl_requires_notification",
                        message: "web.crawl must be submitted through jobs_create so the result can arrive in a notification banner."
                    )
                ],
                retry: ToolExecutionOutcome.Retry(allowed: false)
            )
            return MCPToolCallResultDTO(
                requestID: request.requestID,
                ok: true,
                isError: true,
                text: (try? outcome.encodedJSON()) ?? "",
                message: "Submit web.crawl through jobs_create for notification delivery."
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

        // Shared Lib parser (same as Agent policy path) — handles repaired model JSON.
        // `{}` is a valid empty object for tools with no required args.
        let args: [String: Value]
        do {
            args = try parseToolArgumentsObject(request.argumentsJSON)
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

    private func legacyExecutionContext(from request: MCPToolCallRequest) -> ExecutionContextWire? {
        let active = request.pluginFactoryCreationActive
            || MCPServiceCallContext.shared.pluginFactoryCreationActive
            || TurnProcessContext.effectivePluginFactoryCreationActive
        guard active else { return nil }
        switch request.principal {
        case .agent(let sessionID, let agentID):
            return ExecutionContextWire(
                sessionID: sessionID,
                principal: request.principal,
                agentID: agentID,
                capabilities: [.syncWebCrawl, .hostReviewRetry]
            )
        default:
            return ExecutionContextWire(
                sessionID: "legacy-mcp",
                principal: request.principal,
                agentID: "legacy",
                capabilities: [.syncWebCrawl, .hostReviewRetry]
            )
        }
    }
}

private func pluginFactoryFailureDetail(for error: Error) -> String {
    if let factoryError = error as? PluginFactoryError {
        return factoryError.localizedDescription
    }
    return error.localizedDescription
}
