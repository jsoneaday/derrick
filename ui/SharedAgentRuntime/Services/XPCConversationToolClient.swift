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
            throw MCPServiceClientError.bootstrapFailed(remote.message.isEmpty ? "searchTools failed" : remote.message)
        }
        for dto in remote.tools where !dto.name.hasPrefix("agents_") {
            byName[dto.name] = MCPToolDescriptor(name: dto.name, description: dto.description)
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

        let request = MCPToolCallRequest(
            principal: principal,
            toolName: name,
            argumentsJSON: try encodeArgumentsJSON(arguments),
            helperAPIKey: helperAPIKeyProvider()
        )
        await MainActor.run {
            debugLog("MCPService XPC callTool tool=\(name) principal=\(principal.logLabel)")
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

    private func encodeArgumentsJSON(_ arguments: [String: Value]) throws -> String {
        let jsonDict = arguments.mapValues { toolValueToJSON($0) }
        let data = try JSONSerialization.data(withJSONObject: jsonDict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func toolValueToJSON(_ val: Value) -> Any {
        switch val {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let arr): return arr.map { toolValueToJSON($0) }
        case .object(let obj): return obj.mapValues { toolValueToJSON($0) }
        case .null: return NSNull()
        case .data(_, let data): return data.base64EncodedString()
        }
    }
}
