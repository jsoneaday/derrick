import Foundation
import MCP

public struct MCPToolDescriptor: Hashable, Sendable {
    public let name: String
    public let description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

public struct MCPToolResult: Hashable, Sendable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public protocol MCPBackend: Sendable {
    var identifier: String { get }
    func searchTools(matching query: String) async throws -> [MCPToolDescriptor]
    func callTool(named name: String, arguments: [String: Value]) async throws -> MCPToolResult
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
        let (tools, _) = try await client.listTools()
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tools.compactMap { tool in
            let description = tool.description
            if lowered.isEmpty || tool.name.lowercased().contains(lowered) || description?.lowercased().contains(lowered) == true {
                return MCPToolDescriptor(name: tool.name, description: description)
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
}
