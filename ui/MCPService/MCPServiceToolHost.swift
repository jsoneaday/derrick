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

/// MCP effectors hosted in MCPService (`script_exec` + factory plugin tools +
/// session memory). No agents_* tools.
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
        // Mid-flight egress via helper→UI serviceName reverse channel remains the backstop.
        await HostHTTPClient.shared.setAccessGate(BlacklistHTTPAccessGate(repository: repo))
        let factorySettings = await MainActor.run {
            LLMModelSettings(repository: repo)
        }
        await factorySettings.loadSettings()
        let factoryExecutor = SwiftPluginFactoryDockerExecutor(
            executor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor()
        )
        let factoryService = ConfiguredPluginFactoryService(
            repository: repo,
            settings: factorySettings,
            executor: factoryExecutor,
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
                    try await factoryService.build(userGoal: goal)
                }
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
                    return try await self.runApprovedPlugin(
                        release.compiledArtifact,
                        input: input,
                        executor: factoryExecutor
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
            message: "MCP tool host ready (script_exec)",
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
            memorySessionKey: sessionKey
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
        return MCPToolCallResultDTO(
            requestID: request.requestID,
            ok: true,
            isError: isError,
            text: result.text,
            message: message
        )
    }

    private func runApprovedPlugin(
        _ artifact: Data,
        input: Data,
        executor: SwiftPluginFactoryDockerExecutor
    ) async throws -> PluginFactoryExecutionResult {
        try await PluginHostHopDispatcher.run(
            initialInput: input,
            execute: { nextInput in
                try await executor.runCompiledArtifact(artifact, input: nextInput)
            }
        )
    }
}
