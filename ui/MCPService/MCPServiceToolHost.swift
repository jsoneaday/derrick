import Foundation
import DBRepository
import MCP
import MCPClient
import MCPServer
import MCPToolCatalog
import MemorySystem
import ServiceContracts

/// In-process MCP server hosted by MCPService (python + catalog; no agent orchestration tools).
actor MCPServiceToolHost {
    static let shared = MCPServiceToolHost()

    private var bridge: MCPLocalBridge?
    private var memoryCoordinator: MemoryCoordinator?

    func ensureReady() async throws -> MCPLocalBridge {
        if let bridge { return bridge }

        let repo = try await MCPServiceStore.shared.sharedRepository()
        let budget = MemoryBudget(maxTokenCount: 200_000)
        let coordinator = MemoryCoordinator(
            store: repo,
            summarizer: DefaultMemorySummarizer(),
            policy: TieredMemoryCompactionPolicy(),
            budget: budget
        )
        memoryCoordinator = coordinator

        // Direct docker CLI (UI prewarms warm containers). Egress mid-flight still via helper→UI.
        // Policy / usage limits run in AgentService before XPC callTool.
        let made = try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(
                runner: DockerPythonScriptRunner(),
                reviewer: nil,
                networkPreflight: { _, _ in nil },
                logger: { message in
                    fputs("[MCPService] \(message)\n", stderr)
                    Task {
                        await MCPServiceStore.shared.log(level: .debug, message: message, code: "tool")
                    }
                }
            )
            await server.registerSessionMemorySearchTool { arguments in
                let sessionKey = MCPServiceCallSlots.shared.memorySessionKey
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
            // agents_* stay on AgentService (need HierarchicalOrchestrator).
        }
        bridge = made
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
        MCPServiceCallSlots.shared.install(memorySessionKey: sessionKey)
        defer { MCPServiceCallSlots.shared.clear() }

        let args = try Self.decodeArgumentsJSON(request.argumentsJSON)
        let result = try await client.callTool(named: request.toolName, arguments: args)
        return MCPToolCallResultDTO(
            requestID: request.requestID,
            ok: true,
            isError: result.isError,
            text: result.text,
            message: result.isError ? "tool reported error" : "ok"
        )
    }

    private static func decodeArgumentsJSON(_ json: String) throws -> [String: Value] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw MCPServiceToolHostError.invalidArguments("argumentsJSON is not UTF-8")
        }
        let any = try JSONSerialization.jsonObject(with: data)
        guard let dict = any as? [String: Any] else {
            throw MCPServiceToolHostError.invalidArguments("argumentsJSON must be a JSON object")
        }
        var out: [String: Value] = [:]
        for (key, value) in dict {
            out[key] = try valueToMCP(value)
        }
        return out
    }

    private static func valueToMCP(_ any: Any) throws -> Value {
        switch any {
        case is NSNull:
            return .null
        case let b as Bool:
            return .bool(b)
        case let i as Int:
            return .int(i)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            if n.doubleValue.rounded() == n.doubleValue,
               n.doubleValue >= Double(Int.min),
               n.doubleValue <= Double(Int.max) {
                return .int(n.intValue)
            }
            return .double(n.doubleValue)
        case let s as String:
            return .string(s)
        case let arr as [Any]:
            return .array(try arr.map { try valueToMCP($0) })
        case let obj as [String: Any]:
            var map: [String: Value] = [:]
            for (k, v) in obj {
                map[k] = try valueToMCP(v)
            }
            return .object(map)
        default:
            throw MCPServiceToolHostError.invalidArguments("unsupported JSON value type \(type(of: any))")
        }
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

/// Process slots for MCP tool handlers (unstructured tasks do not inherit TaskLocal).
private final class MCPServiceCallSlots: @unchecked Sendable {
    static let shared = MCPServiceCallSlots()

    private let lock = NSLock()
    private var sessionKey: MemorySessionKey?

    private init() {}

    func install(memorySessionKey: MemorySessionKey) {
        lock.lock()
        sessionKey = memorySessionKey
        lock.unlock()
    }

    func clear() {
        lock.lock()
        sessionKey = nil
        lock.unlock()
    }

    var memorySessionKey: MemorySessionKey? {
        lock.lock()
        defer { lock.unlock() }
        return sessionKey
    }
}
