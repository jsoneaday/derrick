import Foundation
import MCP

public struct MCPServerTool: Hashable, Sendable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public actor MCPToolRegistry {
    public typealias Handler = @Sendable ([String: Value]) async throws -> String

    private var handlers: [String: (description: String, handler: Handler)] = [:]

    public init() {}

    public func register(name: String, description: String, handler: @escaping Handler) {
        handlers[name] = (description, handler)
    }

    public func search(matching query: String) -> [MCPServerTool] {
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return handlers.compactMap { name, entry in
            if lowered.isEmpty || name.lowercased().contains(lowered) || entry.description.lowercased().contains(lowered) {
                return MCPServerTool(name: name, description: entry.description)
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
                )
            ]
            return .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [registry] params in
            switch params.name {
            case "tool_search":
                let query = params.arguments?["query"]?.stringValue ?? ""
                let results = await registry.search(matching: query)
                let lines = results.map { "\($0.name) - \($0.description)" }
                return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)], isError: false)

            case "tool":
                let name = params.arguments?["name"]?.stringValue ?? ""
                let input = params.arguments?["arguments"]?.stringValue ?? "{}"
                let decoded = Self.decodeArguments(from: input)
                let result = try await registry.call(name: name, arguments: decoded)
                return .init(content: [.text(text: result, annotations: nil, _meta: nil)], isError: false)

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
}
