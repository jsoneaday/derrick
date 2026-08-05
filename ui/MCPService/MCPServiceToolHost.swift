import Foundation
import DBRepository
import Lib
import MCP
import MCPClient
import MCPServer
import MCPToolCatalog
import MemorySystem
import ServiceContracts

/// MCP effectors hosted in MCPService (python + session memory). No agents_* tools.
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

        // Direct docker CLI (UI prewarms containers).
        // Network host preflight runs in AgentService (has reverse-XPC to UI) before callTool.
        // Mid-flight egress via helper→UI remains a backstop for dynamic hosts.
        let made = try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(
                runner: DockerPythonScriptRunner(),
                reviewer: MCPServicePythonReviewer(),
                networkPreflight: { _, _ in nil },
                logger: { message in
                    fputs("[MCPService] \(message)\n", stderr)
                    Task {
                        await MCPServiceStore.shared.log(level: .debug, message: message, code: "tool")
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
                        page: arguments.page
                    )
                )
                return retrieval.context
            }
        }
        host = made
        await MCPServiceStore.shared.log(
            level: .info,
            message: "MCP tool host ready (python + session_memory; no agents_*)",
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
        return tools.map {
            MCPToolDescriptorDTO(name: $0.name, description: $0.description ?? "")
        }
    }

    func callTool(request: MCPToolCallRequest) async throws -> MCPToolCallResultDTO {
        let client = try await ensureReady().client
        await MCPServiceStore.shared.log(
            level: .info,
            message: "callTool principal=\(request.principal.logLabel) tool=\(request.toolName)",
            code: "call_tool",
            detailJSON: #"{"requestID":"\#(request.requestID)"}"#
        )

        if request.toolName.hasPrefix("agents_") {
            return MCPToolCallResultDTO(
                requestID: request.requestID,
                ok: false,
                isError: true,
                text: "",
                message: "Tool \(request.toolName) is owned by AgentService, not MCPService."
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
            memorySessionKey: sessionKey
        )
        defer { MCPServiceCallContext.shared.clear() }

        // Shared Lib parser (same as Agent policy path) — handles repaired model JSON.
        let args = try parseToolArgumentsObject(request.argumentsJSON)
        if args.isEmpty, !request.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPServiceToolHostError.invalidArguments(
                "argumentsJSON did not parse (len=\(request.argumentsJSON.count))"
            )
        }
        let result = try await client.callTool(named: request.toolName, arguments: args)
        return MCPToolCallResultDTO(
            requestID: request.requestID,
            ok: true,
            isError: result.isError,
            text: result.text,
            message: result.isError ? "tool reported error" : "ok"
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
