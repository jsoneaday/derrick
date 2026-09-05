import Foundation
import MCP
import MCPClient
import MCPToolCatalog
import Structure

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

private func toolExecutionOutcomeIsError(_ text: String) -> Bool {
    ToolExecutionOutcome.decode(from: text)?.indicatesFailure ?? false
}

public actor MCPToolRegistry {
    public typealias Handler = MCPToolHandler

    private var handlers: [String: (description: String, inputSchema: Value, handler: Handler)] = [:]

    public init() {}

    /// Registers a catalog tool (preferred public path).
    public func register(
        tool: AllowedMCPTool,
        description: String,
        inputSchema: Value = .object([:]),
        handler: @escaping Handler
    ) {
        handlers[tool.rawValue] = (description, inputSchema, handler)
    }

    public func register(_ registration: MCPToolRegistration) {
        register(
            tool: registration.tool,
            description: registration.description,
            inputSchema: registration.inputSchema,
            handler: registration.handler
        )
    }

    /// Test / meta-tool escape hatch. Prefer `AllowedMCPTool` for product tools.
    func registerRaw(name: String, description: String, inputSchema: Value = .object([:]), handler: @escaping Handler) {
        handlers[name] = (description, inputSchema, handler)
    }

    public func search(matching query: String) -> [MCPToolDescriptor] {
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return handlers.compactMap { name, entry in
            if lowered.isEmpty || name.lowercased().contains(lowered) || entry.description.lowercased().contains(lowered) {
                return MCPToolDescriptor(name: name, description: entry.description, inputSchema: entry.inputSchema)
            }
            return nil
        }
        .sorted { $0.name < $1.name }
    }

    public func call(name: String, arguments: [String: Value]) async throws -> String {
        guard let entry = handlers[name] else {
            throw NSError(domain: "MCPServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Unknown tool \(name)."])
        }
        return try await entry.handler(arguments)
    }

    public func batchCall(_ request: MCPToolBatchRequest) async -> MCPToolBatchResult {
        let count = request.invocations.count
        guard count > 0 else {
            return MCPToolBatchResult(results: [], combinedContent: "", isError: false)
        }

        // Concurrent fan-out; result order matches invocation order.
        let results: [MCPToolResult] = await withTaskGroup(of: (Int, MCPToolResult).self) { group in
            for (index, invocation) in request.invocations.enumerated() {
                group.addTask {
                    do {
                        let content = try await self.call(name: invocation.toolName, arguments: invocation.arguments)
                        return (
                            index,
                            MCPToolResult(
                                content: [MCPToolContent.text(content)],
                                isError: toolExecutionOutcomeIsError(content)
                            )
                        )
                    } catch {
                        print("[MCPServer] batch call failed for \(invocation.toolName): \(error)")
                        return (
                            index,
                            MCPToolResult(content: [MCPToolContent.text(error.localizedDescription)], isError: true)
                        )
                    }
                }
            }
            var ordered = Array<MCPToolResult?>(repeating: nil, count: count)
            for await (index, result) in group {
                ordered[index] = result
            }
            return ordered.compactMap { $0 }
        }

        return MCPToolBatchResult(
            results: results,
            combinedContent: Self.combine(results: results, filterQuery: request.filterQuery),
            isError: results.contains(where: \.isError)
        )
    }

    private static func combine(results: [MCPToolResult], filterQuery: String?) -> String {
        let joined = results.map(\.text).joined(separator: "\n\n")
        let trimmedQuery = filterQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuery.isEmpty else {
            return joined
        }

        let tokens = trimmedQuery
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return joined
        }

        let lines = joined.components(separatedBy: .newlines)
        let filtered = lines.filter { line in
            let lowered = line.lowercased()
            return tokens.allSatisfy { lowered.contains($0) }
        }
        return filtered.joined(separator: "\n")
    }
}

public final class MCPServerHost: MCPToolRegistering, @unchecked Sendable {
    private let server: Server
    private let registry: MCPToolRegistry

    public init(name: String = "MCPServer", version: String = "1.0.0", registry: MCPToolRegistry = MCPToolRegistry()) {
        self.registry = registry
        self.server = Server(
            name: name,
            version: version,
            capabilities: .init(tools: .init(listChanged: true))
        )
    }

    public func register(_ registration: MCPToolRegistration) async {
        await registry.register(registration)
    }

    public func register(
        tool: AllowedMCPTool,
        description: String,
        inputSchema: Value = .object([:]),
        handler: @escaping MCPToolRegistry.Handler
    ) async {
        await registry.register(
            tool: tool,
            description: description,
            inputSchema: inputSchema,
            handler: handler
        )
    }

    /// Preferred name for catalog registration (alias of `register(tool:…)`).
    public func registerTool(
        tool: AllowedMCPTool,
        description: String,
        inputSchema: Value = .object([:]),
        handler: @escaping MCPToolRegistry.Handler
    ) async {
        await register(tool: tool, description: description, inputSchema: inputSchema, handler: handler)
    }

    public func searchRegisteredTools(matching query: String) async -> [MCPToolDescriptor] {
        await registry.search(matching: query)
    }

    public func executeBatch(_ request: MCPToolBatchRequest) async -> MCPToolBatchResult {
        await registry.batchCall(request)
    }

    public func registerSessionMemorySearchTool(
        description: String? = nil,
        handler: @escaping @Sendable (SessionMemorySearchArguments) async throws -> String
    ) async {
        await register(SessionMemorySearchToolModule.makeRegistration(description: description, handler: handler))
    }

    public func start(transport: any Transport) async throws {
        await installHandlers()
        try await server.start(transport: transport)
    }

    public func startStdio() async throws {
        try await start(transport: StdioTransport())
    }

    public func startHTTP(endpoint: URL) async throws {
        await installHandlers()
        try await server.start(transport: HTTPClientTransport(endpoint: endpoint, streaming: true))
    }

    private func installHandlers() async {
        await server.withMethodHandler(ListTools.self) { [registry] _ in
            let registeredTools = await registry.search(matching: "").map { descriptor in
                Tool(
                    name: descriptor.name,
                    description: descriptor.description,
                    inputSchema: descriptor.inputSchema ?? .object([:])
                )
            }

            let tools: [Tool] = [
                Tool(
                    name: "tool_search",
                    description: "Search registered tools by name or description.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([.string("query")])
                    ])
                ),
                Tool(
                    name: "tool",
                    description: "Call a registered tool by name.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string")
                            ]),
                            "arguments": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "tool_batch",
                    description: "Call multiple registered tools and aggregate the results.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "request_json": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([.string("request_json")])
                    ])
                )
            ] + registeredTools
            return .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [registry] params in
            switch params.name {
            case "tool_search":
                let query = params.arguments?["query"]?.stringValue ?? ""
                let results = await registry.search(matching: query)
                return .init(content: [.text(text: Self.encodeJSON(results), annotations: nil, _meta: nil)], isError: false)

            case "tool":
                let name = params.arguments?["name"]?.stringValue ?? ""
                let input = params.arguments?["arguments"]?.stringValue ?? "{}"
                let decoded = Self.decodeArguments(from: input)
                let result = try await registry.call(name: name, arguments: decoded)
                return .init(
                    content: [.text(text: result, annotations: nil, _meta: nil)],
                    isError: Self.isExecutionOutcomeError(result)
                )

            case "tool_batch":
                let input = params.arguments?["request_json"]?.stringValue ?? "{}"
                let request = Self.decodeBatchRequest(from: input)
                let result = await registry.batchCall(request)
                return .init(
                    content: [.text(text: Self.encodeJSON(result), annotations: nil, _meta: nil)],
                    isError: result.isError
                )

            default:
                do {
                    let result = try await registry.call(name: params.name, arguments: params.arguments ?? [:])
                    return .init(
                        content: [.text(text: result, annotations: nil, _meta: nil)],
                        isError: Self.isExecutionOutcomeError(result)
                    )
                } catch {
                    print("[MCPServer] tool call failed for \(params.name): \(error)")
                    return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
                }
            }
        }
    }
    private static func decodeArguments(from input: String) -> [String: Value] {
        guard let data = input.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: Value].self, from: data) else {
            return [:]
        }
        return object
    }

    private static func decodeBatchRequest(from input: String) -> MCPToolBatchRequest {
        guard let data = input.data(using: .utf8),
              let request = try? JSONDecoder().decode(MCPToolBatchRequest.self, from: data) else {
            return MCPToolBatchRequest(invocations: [])
        }
        return request
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isExecutionOutcomeError(_ text: String) -> Bool {
        toolExecutionOutcomeIsError(text)
    }

    private static func integerValue(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}

public final class MCPLocalBridge: @unchecked Sendable {
    public let server: MCPServerHost
    public let client: MCPClient

    private init(server: MCPServerHost, client: MCPClient) {
        self.server = server
        self.client = client
    }

    public static func make(
        serverName: String = "MCPServer",
        serverVersion: String = "1.0.0",
        clientName: String = "MCPClient",
        clientVersion: String = "1.0.0",
        configure: @escaping @Sendable (MCPServerHost) async throws -> Void = { _ in }
    ) async throws -> MCPLocalBridge {
        let server = MCPServerHost(name: serverName, version: serverVersion)
        try await configure(server)

        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite
        )

        let backend = MCPStdioBackend(
            identifier: "local-stdio",
            name: clientName,
            version: clientVersion,
            transport: clientTransport
        )
        let client = MCPClient(backend: backend)

        try await server.start(transport: serverTransport)
        return MCPLocalBridge(server: server, client: client)
    }
}
