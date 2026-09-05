import Foundation
import MCP

/// Handler signature for MCP tool invocations.
public typealias MCPToolHandler = @Sendable ([String: Value]) async throws -> String

/// Fully built registration payload: catalog identity + schema + handler.
/// Tool-specific modules construct this; the host only stores it.
public struct MCPToolRegistration: Sendable {
    public let tool: AllowedMCPTool
    public let description: String
    public let inputSchema: Value
    public let handler: MCPToolHandler

    public init(
        tool: AllowedMCPTool,
        description: String? = nil,
        inputSchema: Value,
        handler: @escaping MCPToolHandler
    ) {
        self.tool = tool
        self.description = description ?? tool.defaultDescription
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// Single registration surface for first-class product tools.
public protocol MCPToolRegistering: Sendable {
    func register(_ registration: MCPToolRegistration) async
    func register(
        tool: AllowedMCPTool,
        description: String,
        inputSchema: Value,
        handler: @escaping MCPToolHandler
    ) async
}

public extension MCPToolRegistering {
    func register(
        tool: AllowedMCPTool,
        description: String,
        inputSchema: Value,
        handler: @escaping MCPToolHandler
    ) async {
        await register(
            MCPToolRegistration(
                tool: tool,
                description: description,
                inputSchema: inputSchema,
                handler: handler
            )
        )
    }
}

/// Guide for tool modules: stable catalog id + schema; build `MCPToolRegistration` from dependencies.
public protocol MCPToolModule {
    static var id: AllowedMCPTool { get }
    static var defaultDescription: String { get }
    static var inputSchema: Value { get }
}

public extension MCPToolModule {
    static var defaultDescription: String { id.defaultDescription }
}
