import Foundation
import MCP
import MCPClient

public actor MCPToolRegistry {
    public typealias Handler = @Sendable ([String: Value]) async throws -> String

    private var handlers: [String: (description: String, handler: Handler)] = [:]

    public init() {}

    public func register(name: String, description: String, handler: @escaping Handler) {
        handlers[name] = (description, handler)
    }

    public func search(matching query: String) -> [MCPToolDescriptor] {
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return handlers.compactMap { name, entry in
            if lowered.isEmpty || name.lowercased().contains(lowered) || entry.description.lowercased().contains(lowered) {
                return MCPToolDescriptor(name: name, description: entry.description)
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
        var results: [MCPToolResult] = []

        for invocation in request.invocations {
            do {
                let content = try await call(name: invocation.name, arguments: invocation.arguments)
                results.append(MCPToolResult(content: content))
            } catch {
                print("[MCPServer] batch call failed for \(invocation.name): \(error)")
                results.append(MCPToolResult(content: error.localizedDescription, isError: true))
            }
        }

        return MCPToolBatchResult(
            results: results,
            combinedContent: Self.combine(results: results, filterQuery: request.filterQuery),
            isError: results.contains(where: \.isError)
        )
    }

    private static func combine(results: [MCPToolResult], filterQuery: String?) -> String {
        let joined = results.map(\.content).joined(separator: "\n\n")
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

public final class MCPServerHost: @unchecked Sendable {
    private let server: Server
    private let registry: MCPToolRegistry

    public init(name: String = "MCPServer", version: String = "1.0.0", registry: MCPToolRegistry = MCPToolRegistry()) {
        self.registry = registry
        self.server = Server(
            name: name,
            version: version,
            capabilities: .init(tools: .init(listChanged: true))
        )
        Task { await self.installHandlers() }
    }

    public func registerTool(name: String, description: String, handler: @escaping MCPToolRegistry.Handler) async {
        await registry.register(name: name, description: description, handler: handler)
    }

    public func searchRegisteredTools(matching query: String) async -> [MCPToolDescriptor] {
        await registry.search(matching: query)
    }

    public func executeBatch(_ request: MCPToolBatchRequest) async -> MCPToolBatchResult {
        await registry.batchCall(request)
    }

    public func registerSessionMemorySearchTool(
        description: String = "Search session memory for relevant context.",
        handler: @escaping @Sendable (String) async throws -> String
    ) async {
        await registry.register(name: "session_memory_search", description: description) { arguments in
            let query = arguments["query"]?.stringValue ?? ""
            return try await handler(query)
        }
    }

    public func startStdio() async throws {
        try await server.start(transport: StdioTransport())
    }

    public func startHTTP(endpoint: URL) async throws {
        try await server.start(transport: HTTPClientTransport(endpoint: endpoint, streaming: true))
    }

    private func installHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
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
            ]
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
                return .init(content: [.text(text: result, annotations: nil, _meta: nil)], isError: false)

            case "tool_batch":
                let input = params.arguments?["request_json"]?.stringValue ?? "{}"
                let request = Self.decodeBatchRequest(from: input)
                let result = await registry.batchCall(request)
                return .init(content: [.text(text: Self.encodeJSON(result), annotations: nil, _meta: nil)], isError: false)

            default:
                return .init(content: [.text(text: "Unknown tool \(params.name).", annotations: nil, _meta: nil)], isError: true)
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

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
