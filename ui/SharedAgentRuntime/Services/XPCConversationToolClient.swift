import Foundation
import Lib
import MCP
import MCPClient
import ServiceContracts

/// Effector tools → MCPService over XPC. Orchestration tools (`agents_*`) stay on a local MCP client.
public struct XPCConversationToolClient: ConversationToolClient, Sendable {
    private let principal: ServicePrincipal
    private let agentsClient: MCPClient?
    private let helperAPIKeyProvider: @Sendable () -> String?

    public init(
        principal: ServicePrincipal,
        agentsClient: MCPClient? = nil,
        helperAPIKeyProvider: @escaping @Sendable () -> String? = { TurnProcessContext.effectiveAPIKey }
    ) {
        self.principal = principal
        self.agentsClient = agentsClient
        self.helperAPIKeyProvider = helperAPIKeyProvider
    }

    public func searchTools(matching query: String) async throws -> [MCPToolDescriptor] {
        var byName: [String: MCPToolDescriptor] = [:]

        if let agentsClient {
            for tool in try await agentsClient.searchTools(matching: query) where tool.name.hasPrefix("agents_") {
                byName[tool.name] = tool
            }
        }

        let remote = try await MCPServiceClient.shared.searchTools(principal: principal, query: query)
        guard remote.ok else {
            throw MCPServiceClientError.meshUnverified(
                remote.message.isEmpty ? "searchTools failed" : remote.message
            )
        }
        for dto in remote.tools where !dto.name.hasPrefix("agents_") {
            byName[dto.name] = MCPToolDescriptor(name: dto.name, description: dto.description)
        }
        // Effector catalog must be non-empty; agents_* alone is not a working mesh.
        let effectors = byName.keys.filter { !$0.hasPrefix("agents_") }
        guard !effectors.isEmpty else {
            throw MCPServiceClientError.meshUnverified("MCPService returned no effector tools")
        }

        return Array(byName.values).sorted { $0.name < $1.name }
    }

    public func callTool(named name: String, arguments: [String: Value]) async throws -> MCPToolResult {
        if name.hasPrefix("agents_") {
            guard let agentsClient else {
                return MCPToolResult(
                    content: [.text("Agent orchestration tools unavailable.")],
                    isError: true
                )
            }
            return try await agentsClient.callTool(named: name, arguments: arguments)
        }

        let argumentsJSON = try toolArgumentsToJSON(arguments)
        let request = MCPToolCallRequest(
            principal: principal,
            toolName: name,
            argumentsJSON: argumentsJSON,
            helperAPIKey: helperAPIKeyProvider()
        )
        await MainActor.run {
            debugLog(
                "MCPService XPC callTool tool=\(name) principal=\(principal.logLabel) argKeys=\(arguments.keys.sorted().joined(separator: ","))"
            )
        }
        let dto = try await MCPServiceClient.shared.callTool(request)
        if !dto.ok && dto.text.isEmpty {
            return MCPToolResult(
                content: [.text(dto.message.isEmpty ? "MCPService callTool failed" : dto.message)],
                isError: true
            )
        }
        return MCPToolResult(content: [.text(dto.text)], isError: dto.isError || !dto.ok)
    }

    public func batchCallTools(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult {
        var results: [MCPToolResult] = []
        for invocation in request.invocations {
            results.append(try await callTool(named: invocation.toolName, arguments: invocation.arguments))
        }
        let combined = results.map(\.text).joined(separator: "\n")
        return MCPToolBatchResult(
            results: results,
            combinedContent: combined,
            isError: results.contains(where: \.isError)
        )
    }
}
