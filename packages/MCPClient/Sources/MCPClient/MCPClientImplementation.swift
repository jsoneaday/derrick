import Foundation
import MCP
import Structure

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
