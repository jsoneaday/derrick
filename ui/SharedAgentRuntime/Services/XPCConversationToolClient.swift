import Foundation
import MCP
import MCPClient
import AgentRuntime
import Structure

/// Effector tools → MCPService over XPC.
/// Orchestration tools (`agents_*`, `jobs_*`) stay on a local MCP client.
public struct XPCConversationToolClient: ConversationToolClient, Sendable {
    private let principal: ServicePrincipal
    private let agentsClient: MCPClient?
    private let helperAPIKeyProvider: @Sendable () -> String?
    /// JSON `HelperModelWire` for MCP script security reviewer (from `LLMModelSettings`).
    private let helperReviewerModelJSONProvider: @Sendable () async -> String?

    public init(
        principal: ServicePrincipal,
        agentsClient: MCPClient? = nil,
        helperAPIKeyProvider: @escaping @Sendable () -> String? = { TurnProcessContext.effectiveAPIKey },
        helperReviewerModelJSONProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.principal = principal
        self.agentsClient = agentsClient
        self.helperAPIKeyProvider = helperAPIKeyProvider
        self.helperReviewerModelJSONProvider = helperReviewerModelJSONProvider
    }

    private static func isOrchestrationTool(_ name: String) -> Bool {
        name.hasPrefix("agents_") || name.hasPrefix("jobs_")
    }

    /// Routes effector calls to the active agent when TaskLocal caller is set (worker spawn path).
    private func effectivePrincipal() -> ServicePrincipal {
        if let caller = AgentCallContext.caller {
            return .agent(sessionID: caller.sessionID, agentID: caller.agentID)
        }
        return principal
    }

    public func searchTools(matching query: String) async throws -> [MCPToolDescriptor] {
        var byName: [String: MCPToolDescriptor] = [:]

        if let agentsClient {
            for tool in try await agentsClient.searchTools(matching: query)
                where Self.isOrchestrationTool(tool.name)
            {
                byName[tool.name] = tool
            }
        }

        let remote = try await MCPServiceClient.shared.searchTools(principal: effectivePrincipal(), query: query)
        guard remote.ok else {
            throw MCPServiceClientError.meshUnverified(
                remote.message.isEmpty ? "searchTools failed" : remote.message
            )
        }
        for dto in remote.tools where !Self.isOrchestrationTool(dto.name) {
            byName[dto.name] = MCPToolDescriptor(name: dto.name, description: dto.description)
        }
        // Effector catalog must be non-empty; orchestration alone is not a working mesh.
        let effectors = byName.keys.filter { !Self.isOrchestrationTool($0) }
        guard !effectors.isEmpty else {
            throw MCPServiceClientError.meshUnverified("MCPService returned no effector tools")
        }

        return Array(byName.values).sorted { $0.name < $1.name }
    }

    public func callTool(named name: String, arguments: [String: Value]) async throws -> MCPToolResult {
        if Self.isOrchestrationTool(name) {
            guard let agentsClient else {
                return MCPToolResult(
                    content: [.text("Agent orchestration tools unavailable.")],
                    isError: true
                )
            }
            return try await agentsClient.callTool(named: name, arguments: arguments)
        }

        let argumentsJSON = try toolArgumentsToJSON(arguments)
        let reviewerModelJSON = await helperReviewerModelJSONProvider()
        let activePrincipal = effectivePrincipal()
        let executionContextJSON = makeExecutionContextJSON(principal: activePrincipal)
        let request = MCPToolCallRequest(
            principal: activePrincipal,
            toolName: name,
            argumentsJSON: argumentsJSON,
            helperAPIKey: helperAPIKeyProvider(),
            helperReviewerModelJSON: reviewerModelJSON,
            pluginFactoryCreationActive: executionContextJSON != nil
                && TurnProcessContext.effectivePluginFactoryCreationActive,
            executionContextJSON: executionContextJSON
        )
        await MainActor.run {
            let longRunning = MCPToolCallTimeouts.nanoseconds(forToolName: name)
                == MCPToolCallTimeouts.longRunningNanoseconds
            debugLog(
                "MCPService XPC callTool tool=\(name) principal=\(activePrincipal.logLabel) " +
                "argKeys=\(arguments.keys.sorted().joined(separator: ",")) " +
                "reviewerModel=\(reviewerModelJSON ?? "default") " +
                "pluginFactory=\(request.pluginFactoryCreationActive) " +
                "timeoutSec=\(longRunning ? 915 : 15)"
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

    private func makeExecutionContextJSON(principal: ServicePrincipal) -> String? {
        guard TurnProcessContext.effectivePluginFactoryCreationActive else { return nil }
        let sessionID: String
        switch principal {
        case .agent(let sid, _):
            sessionID = sid
        default:
            return nil
        }
        let agentID: String
        if case .agent(_, let aid) = principal {
            agentID = aid
        } else {
            agentID = "ui"
        }
        let wire = ExecutionContextWire(
            sessionID: sessionID,
            principal: principal,
            agentID: agentID,
            workflow: WorkflowContextWire(kind: .pluginFactoryCreate),
            delivery: .liveChat,
            capabilities: [.syncWebCrawl, .hostReviewRetry]
        )
        return try? wire.encodedJSON()
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
