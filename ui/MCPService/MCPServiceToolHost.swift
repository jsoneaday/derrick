import Foundation
import DBRepository
import Lib
import MCP
import MCPClient
import MCPServer
import MCPToolCatalog
import MemorySystem
import ServiceContracts

/// MCP effectors hosted in MCPService (`script_exec` + session memory). No agents_* tools.
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

        // Docker via DockerRunnerHelper peer XPC only — never DockerScriptRunner / local CLI.
        // UI prewarms containers and hands the helper peer endpoint at bootstrap.
        // Network host preflight runs in AgentService (reverse-XPC to UI) before callTool.
        // Mid-flight egress via helper→UI serviceName reverse channel remains the backstop.
        await HostHTTPClient.shared.setAccessGate(BlacklistHTTPAccessGate(repository: repo))
        await HostHTTPClient.shared.setSecretAttacher(PluginHostSecretAttacher(repository: repo))
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
            await PluginFactoryHost.registerTools(
                on: server,
                repository: repo,
                stdinExecutor: MCPServiceDockerHelperRunner.shared.makeStdinCLIExecutor(),
                reviewer: MCPServiceScriptReviewer(),
                logger: { message in
                    fputs("[MCPService] \(message)\n", stderr)
                    Task {
                        await MCPServiceStore.shared.log(level: .debug, message: message, code: "factory")
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
            message: "MCP tool host ready (script_exec + factory + plugin.invoke)",
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
        let repo = try await MCPServiceStore.shared.sharedRepository()
        let sessionID: String?
        if case .agent(let id, _) = principal {
            sessionID = id
        } else {
            sessionID = nil
        }
        return await PluginFactoryHost.searchVisible(
            tools: mapped,
            repository: repo,
            sessionID: sessionID
        )
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
        case .plugin(let pluginID, let version):
            sessionKey = MemorySessionKey(sessionID: "plugin-\(pluginID)", agentID: version)
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
        // `{}` is a valid empty object for tools with no required args (factory.review,
        // factory.promote, plugin.list). factory.build still requires `goal`.
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
}

enum MCPServiceToolHostError: Error, LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let m): return m
        }
    }
}
