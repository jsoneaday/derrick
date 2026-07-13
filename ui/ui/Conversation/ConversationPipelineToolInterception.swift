import Foundation
import MCP
import MCPClient
import MemorySystem

extension ConversationPipeline {
    func callToolWithPolicyInterception(
        named name: String,
        arguments: [String: Value],
        sessionID: String,
        interceptor: ToolRequestInterceptor? = nil,
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil
    ) async throws -> MCPToolResult {
        await MainActor.run {
            debugLog("Tool request given: \(name)")
        }
        let event = ToolInvocationEvent(
            sessionID: sessionID,
            toolName: name,
            argumentsJSON: try toolArgumentsToJSON(arguments)
        )
        await MainActor.run {
            debugLog("Tool request JSON: \(Self.debugPayload(event.argumentsJSON))")
        }

        let effectiveInterceptor = makeToolInterceptor(override: interceptor)

        let interceptedEvent: ToolInvocationEvent
        let decision = try await effectiveInterceptor.evaluateToolInvocation(event)
        await MainActor.run {
            debugLog("Policy rule processing: evaluating \(name)")
        }
        switch decision {
        case .allow(let allowedEvent):
            interceptedEvent = allowedEvent
            await MainActor.run {
                debugLog("Policy decision: allow \(name)")
            }
        case .deny(let reason):
            await MainActor.run {
                debugLog("Policy decision: deny \(name)")
            }
            try await policyStore?.saveApproval(
                PolicyApproval(
                    applicationName: applicationName,
                    sessionID: sessionID,
                    ruleID: "runtime-confirmation",
                    requestType: "tool_invocation",
                    requestPayloadJSON: event.argumentsJSON,
                    editedPayloadJSON: nil,
                    decision: "denied",
                    actor: "policy-engine",
                    createdAt: .now,
                    acedAt: .now
                )
            )
            try await persistPolicyDecision(
                sessionID: sessionID,
                requestPayloadJSON: event.argumentsJSON,
                decision: "denied",
                actor: "policy-engine"
            )
            throw MCPClientError.toolExecutionDenied(toolName: name, reason: reason)
        case .confirm(let confirmEvent, let requiredFields):
            await MainActor.run {
                debugLog("Policy decision: confirm \(name)")
            }
            guard let approvalPresenter else {
                try await policyStore?.saveApproval(
                    PolicyApproval(
                        applicationName: applicationName,
                        sessionID: sessionID,
                        ruleID: "runtime-confirmation",
                        requestType: "tool_invocation",
                        requestPayloadJSON: event.argumentsJSON,
                        editedPayloadJSON: nil,
                        decision: "cancelled",
                        actor: "system",
                        createdAt: .now,
                        acedAt: .now
                    )
                )
                try await persistPolicyDecision(
                    sessionID: sessionID,
                    requestPayloadJSON: event.argumentsJSON,
                    decision: "cancelled",
                    actor: "system"
                )
                throw MCPClientError.toolExecutionDenied(
                    toolName: name,
                    reason: "Tool execution requires user confirmation"
                )
            }

            let confirmationRequest = ApprovalConfirmationRequest(
                sessionID: sessionID,
                toolName: confirmEvent.toolName,
                argumentsJSON: confirmEvent.argumentsJSON,
                requiredFields: requiredFields
            )
            let confirmation = await approvalPresenter.confirm(confirmationRequest)
            await MainActor.run {
                debugLog("Approval response received for \(name)")
            }
            let approvalRecord = PolicyApproval.fromApprovalDecision(
                applicationName: applicationName,
                sessionID: sessionID,
                requestPayloadJSON: confirmEvent.argumentsJSON,
                decision: confirmation
            )
            try await policyStore?.saveApproval(approvalRecord)

            switch confirmation {
            case .approved(let editedArgumentsJSON, let actor):
                await MainActor.run {
                    debugLog("Approval granted for \(name) by \(actor)")
                }
                try await persistPolicyDecision(
                    sessionID: sessionID,
                    requestPayloadJSON: confirmEvent.argumentsJSON,
                    decision: "approved",
                    actor: actor
                )
                interceptedEvent = ToolInvocationEvent(
                    sessionID: confirmEvent.sessionID,
                    toolName: confirmEvent.toolName,
                    argumentsJSON: editedArgumentsJSON,
                    timestamp: confirmEvent.timestamp
                )
            case .cancelled(let actor):
                await MainActor.run {
                    debugLog("Approval cancelled for \(name) by \(actor)")
                }
                try await persistPolicyDecision(
                    sessionID: sessionID,
                    requestPayloadJSON: confirmEvent.argumentsJSON,
                    decision: "cancelled",
                    actor: actor
                )
                throw MCPClientError.toolExecutionDenied(
                    toolName: name,
                    reason: "User cancelled the approval request"
                )
            }
        }

        let interceptedArguments = try toolArgumentsFromJSON(interceptedEvent.argumentsJSON)
        guard let mcpClient else {
            return MCPToolResult(content: "Tool client unavailable.", isError: true)
        }
        if interceptedEvent.toolName == "python_script_exec" {
            await MainActor.run {
                debugLog("Python reviewer validating request")
            }
        }
        await MainActor.run {
            debugLog("Executing tool: \(interceptedEvent.toolName)")
        }
        let result = try await mcpClient.callTool(named: interceptedEvent.toolName, arguments: interceptedArguments)
        await MainActor.run {
            debugLog("Tool result: \(interceptedEvent.toolName) (isError=\(result.isError))")
            debugLog("Tool result content: \(Self.debugPayload(result.content))")
        }
        return result
    }

    func batchCallToolsWithPolicyInterception(
        _ request: MCPToolBatchRequest,
        sessionID: String,
        interceptor: ToolRequestInterceptor? = nil,
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil
    ) async throws -> MCPToolBatchResult {
        var results: [MCPToolResult] = []

        for invocation in request.invocations {
            do {
                let result = try await callToolWithPolicyInterception(
                    named: invocation.name,
                    arguments: invocation.arguments,
                    sessionID: sessionID,
                    interceptor: interceptor,
                    approvalPresenter: approvalPresenter
                )
                results.append(result)
            } catch MCPClientError.toolExecutionDenied(let toolName, let reason) {
                results.append(MCPToolResult(content: "\(toolName) \(reason)", isError: true))
            }
        }

        let hasErrors = results.contains(where: \.isError)
        return MCPToolBatchResult(
            results: results,
            combinedContent: results.map(\.content).joined(separator: "\n"),
            isError: hasErrors
        )
    }

    private func makeToolInterceptor(override: ToolRequestInterceptor?) -> ToolRequestInterceptor {
        if let override {
            return override
        }
        if let policyStore {
            let policy = OnDemandToolGovernancePolicy(store: policyStore, applicationName: applicationName)
            return DefaultToolRequestInterceptor(policy: policy)
        }
        return DefaultToolRequestInterceptor()
    }

    private func persistPolicyDecision(
        sessionID: String,
        requestPayloadJSON: String,
        decision: String,
        actor: String?
    ) async throws {
        try await policyStore?.logAuditEntry(
            PolicyAuditLogEntry(
                applicationName: applicationName,
                sessionID: sessionID,
                eventType: "tool_invocation",
                scope: "tool_invocation",
                requestJSON: requestPayloadJSON,
                decision: decision,
                actor: actor
            )
        )
    }

    private func toolArgumentsToJSON(_ arguments: [String: Value]) throws -> String {
        let jsonDict = arguments.mapValues { (val: Value) -> Any in
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
        let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [.sortedKeys])
        return String(data: jsonData, encoding: .utf8) ?? "{}"
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

    private func toolArgumentsFromJSON(_ json: String) throws -> [String: Value] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj.mapValues { jsonToToolValue($0) }
    }

    private func jsonToToolValue(_ obj: Any) -> Value {
        if let str = obj as? String {
            return .string(str)
        } else if let num = obj as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .bool(num.boolValue)
            } else if num.doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                return .int(num.intValue)
            } else {
                return .double(num.doubleValue)
            }
        } else if let bool = obj as? Bool {
            return .bool(bool)
        } else if let arr = obj as? [Any] {
            return .array(arr.map { jsonToToolValue($0) })
        } else if let dict = obj as? [String: Any] {
            return .object(dict.mapValues { jsonToToolValue($0) })
        }
        return .null
    }

    private static func debugPayload(_ payload: String, limit: Int = 12_000) -> String {
        guard payload.count > limit else {
            return payload
        }
        return String(payload.prefix(limit)) + "\n... [truncated \(payload.count - limit) chars]"
    }
}

public enum MCPClientError: Error, Sendable {
    case toolExecutionDenied(toolName: String, reason: String)
}

extension MCPClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .toolExecutionDenied(let toolName, let reason):
            return "\(toolName) \(reason)"
        }
    }
}
