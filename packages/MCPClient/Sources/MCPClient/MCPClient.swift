import Foundation
import MCP

public struct MCPToolDescriptor: Hashable, Codable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: Value?

    public init(name: String, description: String? = nil, inputSchema: Value? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPToolResult: Hashable, Codable, Sendable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public struct MCPSingleToolRequest: Decodable {
    public let toolName: String
    public let arguments: [String: Value]?
    
    public init(toolName: String, arguments: [String: Value]? = nil) {
        self.toolName = toolName
        self.arguments = arguments
    }
}

public struct MCPToolInvocation: Hashable, Codable, Sendable {
    public let toolName: String
    public let arguments: [String: Value]

    public init(name: String, arguments: [String: Value] = [:]) {
        self.toolName = name
        self.arguments = arguments
    }
}

public struct MCPToolBatchRequest: Hashable, Codable, Sendable {
    public let invocations: [MCPToolInvocation]
    public let filterQuery: String?

    public init(invocations: [MCPToolInvocation], filterQuery: String? = nil) {
        self.invocations = invocations
        self.filterQuery = filterQuery
    }
}

public struct MCPToolBatchResult: Hashable, Codable, Sendable {
    public let results: [MCPToolResult]
    public let combinedContent: String
    public let isError: Bool

    public init(results: [MCPToolResult], combinedContent: String, isError: Bool = false) {
        self.results = results
        self.combinedContent = combinedContent
        self.isError = isError
    }
}

public protocol MCPBackend: Sendable {
    var identifier: String { get }
    func searchTools(matching query: String) async throws -> [MCPToolDescriptor]
    func callTool(named name: String, arguments: [String: Value]) async throws -> MCPToolResult
    func batchCallTools(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult
}

public actor MCPClient {
    private let backend: any MCPBackend

    public init(backend: any MCPBackend) {
        self.backend = backend
    }

    public func searchTools(matching query: String) async throws -> [MCPToolDescriptor] {
        try await backend.searchTools(matching: query)
    }

    public func callTool(named name: String, arguments: [String: Value]) async throws -> MCPToolResult {
        try await backend.callTool(named: name, arguments: arguments)
    }

    public func batchCallTools(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult {
        try await backend.batchCallTools(request)
    }
}

public struct MCPServerProfile: Hashable, Sendable {
    public enum Transport: Hashable, Sendable {
        case stdio
        case http(URL)
    }

    public let name: String
    public let version: String
    public let transport: Transport

    public init(name: String, version: String, transport: Transport) {
        self.name = name
        self.version = version
        self.transport = transport
    }
}

public actor MCPOfficialBackend: MCPBackend {
    public nonisolated let identifier: String
    private let client: Client
    private let transport: MCPServerProfile.Transport

    public init(profile: MCPServerProfile) {
        identifier = profile.name
        client = Client(name: profile.name, version: profile.version)
        transport = profile.transport
    }

    public func connect() async throws {
        switch transport {
        case .stdio:
            _ = try await client.connect(transport: StdioTransport())
        case .http(let endpoint):
            _ = try await client.connect(transport: HTTPClientTransport(endpoint: endpoint, streaming: true))
        }
    }

    public func searchTools(matching query: String) async throws -> [MCPToolDescriptor] {
        if let descriptors = try? await searchViaTool(query: query) {
            return descriptors
        }

        let (tools, _) = try await client.listTools()
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tools.compactMap { tool in
            let description = tool.description
            if lowered.isEmpty || tool.name.lowercased().contains(lowered) || description?.lowercased().contains(lowered) == true {
                return MCPToolDescriptor(name: tool.name, description: description, inputSchema: tool.inputSchema)
            }
            return nil
        }
    }

    public func callTool(named name: String, arguments: [String: Value]) async throws -> MCPToolResult {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        var pieces: [String] = []
        for item in content {
            switch item {
            case .text(text: let text, annotations: _, _meta: _):
                pieces.append(text)
            default:
                pieces.append(String(describing: item))
            }
        }
        return MCPToolResult(content: pieces.joined(separator: "\n"), isError: isError ?? false)
    }

    public func batchCallTools(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult {
        if let batch = try? await batchViaTool(request) {
            return batch
        }

        var results: [MCPToolResult] = []
        for invocation in request.invocations {
            results.append(try await callTool(named: invocation.toolName, arguments: invocation.arguments))
        }

        return MCPToolBatchResult(
            results: results,
            combinedContent: Self.combine(results: results, filterQuery: request.filterQuery),
            isError: results.contains(where: \.isError)
        )
    }

    private func searchViaTool(query: String) async throws -> [MCPToolDescriptor] {
        let result = try await callTool(named: "tool_search", arguments: ["query": .string(query)])
        let data = Data(result.content.utf8)
        return try JSONDecoder().decode([MCPToolDescriptor].self, from: data)
    }

    private func batchViaTool(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult {
        let payload = try JSONEncoder().encode(request)
        let result = try await callTool(
            named: "tool_batch",
            arguments: [
                "request_json": .string(String(decoding: payload, as: UTF8.self))
            ]
        )
        let data = Data(result.content.utf8)
        return try JSONDecoder().decode(MCPToolBatchResult.self, from: data)
    }

    private static func combine(results: [MCPToolResult], filterQuery: String?) -> String {
        let joined = results.map(\.content).joined(separator: "\n\n")
        let trimmedQuery = filterQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuery.isEmpty else {
            return joined
        }

        let tokens = trimmedQuery.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
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

public actor MCPStdioBackend: MCPBackend {
    public nonisolated let identifier: String
    private let client: Client
    private let transport: any Transport
    private var didConnect = false

    public init(identifier: String = "stdio", name: String = "MCPClient", version: String = "1.0.0", transport: any Transport) {
        self.identifier = identifier
        self.client = Client(name: name, version: version)
        self.transport = transport
    }

    public func searchTools(matching query: String) async throws -> [MCPToolDescriptor] {
        try await connectIfNeeded()
        let (tools, _) = try await client.listTools()
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tools.compactMap { tool in
            let description = tool.description
            if lowered.isEmpty || tool.name.lowercased().contains(lowered) || description?.lowercased().contains(lowered) == true {
                return MCPToolDescriptor(name: tool.name, description: description, inputSchema: tool.inputSchema)
            }
            return nil
        }
    }

    public func callTool(named name: String, arguments: [String: Value]) async throws -> MCPToolResult {
        try await connectIfNeeded()
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        var pieces: [String] = []
        for item in content {
            switch item {
            case .text(text: let text, annotations: _, _meta: _):
                pieces.append(text)
            default:
                pieces.append(String(describing: item))
            }
        }
        return MCPToolResult(content: pieces.joined(separator: "\n"), isError: isError ?? false)
    }

    public func batchCallTools(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult {
        try await connectIfNeeded()
        var results: [MCPToolResult] = []
        for invocation in request.invocations {
            results.append(try await callTool(named: invocation.toolName, arguments: invocation.arguments))
        }
        return MCPToolBatchResult(
            results: results,
            combinedContent: results.map(\.content).joined(separator: "\n\n"),
            isError: results.contains(where: \.isError)
        )
    }

    private func connectIfNeeded() async throws {
        guard !didConnect else {
            return
        }
        _ = try await client.connect(transport: transport)
        didConnect = true
    }
}
