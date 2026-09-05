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
