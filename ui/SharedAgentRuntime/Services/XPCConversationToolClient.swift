import Foundation
import Lib
import MCP
import MCPClient
import ServiceContracts

/// Routes effector tools to MCPService over XPC; keeps `agents_*` on a local bridge.
public struct XPCConversationToolClient: ConversationToolClient, Sendable {
    private let principal: ServicePrincipal
    private let localAgentsClient: MCPClient?

    public init(
        principal: ServicePrincipal,
        localAgentsClient: MCPClient? = nil
    ) {
        self.principal = principal
        self.localAgentsClient = localAgentsClient
    }

    public func searchTools(matching query: String) async throws -> [MCPToolDescriptor] {
        var byName: [String: MCPToolDescriptor] = [:]

        if let localAgentsClient {
            let local = try await localAgentsClient.searchTools(matching: query)
            for tool in local where tool.name.hasPrefix("agents_") {
                byName[tool.name] = tool
            }
        }

        do {
            fputs("[XPCConversationToolClient] searchTools via MCPService…\n", stderr)
            let remote = try await MCPServiceClient.shared.searchTools(principal: principal, query: query)
            guard remote.ok else {
                fputs("[XPCConversationToolClient] searchTools not ok: \(remote.message)\n", stderr)
                await MainActor.run {
                    debugLog("MCPService searchTools failed: \(remote.message)")
                }
                return Array(byName.values).sorted { $0.name < $1.name }
            }
            for dto in remote.tools where !dto.name.hasPrefix("agents_") {
                byName[dto.name] = MCPToolDescriptor(name: dto.name, description: dto.description)
            }
            fputs("[XPCConversationToolClient] searchTools ok count=\(remote.tools.count)\n", stderr)
        } catch {
            fputs("[XPCConversationToolClient] searchTools error: \(error.localizedDescription)\n", stderr)
            await MainActor.run {
                debugLog("MCPService searchTools error: \(error.localizedDescription)")
            }
        }

        return Array(byName.values).sorted { $0.name < $1.name }
    }

    public func callTool(named name: String, arguments: [String: Value]) async throws -> MCPToolResult {
        if name.hasPrefix("agents_") {
            guard let localAgentsClient else {
                return MCPToolResult(
                    content: [.text("Agent orchestration tools unavailable (no local bridge).")],
                    isError: true
                )
            }
            return try await localAgentsClient.callTool(named: name, arguments: arguments)
        }

        let argumentsJSON = try encodeArgumentsJSON(arguments)
        let request = MCPToolCallRequest(
            principal: principal,
            toolName: name,
            argumentsJSON: argumentsJSON
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
        let isError = results.contains(where: \.isError)
        return MCPToolBatchResult(results: results, combinedContent: combined, isError: isError)
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
