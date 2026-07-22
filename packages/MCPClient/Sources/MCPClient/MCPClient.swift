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

public enum MCPToolContent: Hashable, Codable, Sendable {
    case text(String)
    case image(data: String, mimeType: String)
    case audio(data: String, mimeType: String)
    case resource(uri: String, mimeType: String?, text: String?, blob: String?)
    case resourceLink(uri: String, name: String, title: String?, description: String?, mimeType: String?)
}

public struct MCPToolResult: Hashable, Codable, Sendable {
    public let content: [MCPToolContent]
    public let isError: Bool
    
    public init(content: [MCPToolContent], isError: Bool) {
        self.content = content
        self.isError = isError
    }

    public var text: String {
        content.compactMap {
            switch $0 {
            case .text(let s):
                return s
            case .image:
                return "image (todo: add image support)"
            case .audio:
                return "audio (todo: add audio support)"
            case .resource(uri: let uri, mimeType: _, text: _, blob: _):
                return uri
            case .resourceLink(uri: _, name: let name, title: _, description: _, mimeType: _):
                return name
            }
        }.joined(separator: "\n")
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
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        var pieces: [MCPToolContent] = []
        for item in content {
            switch item {
            case .text(text: let text, annotations: _, _meta: _):
                pieces.append(MCPToolContent.text(text))
            case .image(data: let data, mimeType: let mimeType, annotations: _, _meta: _):
                pieces.append(MCPToolContent.image(data: data, mimeType: mimeType))
            case .audio(data: let data, mimeType: let mimeType, annotations: _, _meta: _):
                pieces.append(MCPToolContent.audio(data: data, mimeType: mimeType))
            case .resource(resource: let content, annotations: _, _meta: _):
                pieces.append(MCPToolContent.resource(uri: content.uri, mimeType: content.mimeType, text: content.text, blob: content.blob))
            case .resourceLink(uri: let uri, name: let name, title: let title, description: let description, mimeType: let mimeType, annotations: _):
                pieces.append(MCPToolContent.resourceLink(uri: uri, name: name, title: title, description: description, mimeType: mimeType))
            }
        }
        return MCPToolResult(content: pieces, isError: isError ?? false)
    }

    public func batchCallTools(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult {
        try await connectIfNeeded()
        var results: [MCPToolResult] = []
        for invocation in request.invocations {
            results.append(try await callTool(named: invocation.toolName, arguments: invocation.arguments))
        }
        return MCPToolBatchResult(
            results: results,
            combinedContent: results.map(\.text).joined(separator: "\n\n"),
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
