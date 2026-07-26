import Foundation
import MCP
import MCPClient
import MemorySystem
import PolicyRuntime
import Lib
import MCPServer
import AppEvents
import PolicyUserInteraction

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
                debugLog("Policy decision: deny \(name) reason=\(reason)")
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
            let preview: String
            if event.argumentsJSON.count > 1200 {
                preview = String(event.argumentsJSON.prefix(1200)) + "…"
            } else {
                preview = event.argumentsJSON
            }
            await AppEventBus.shared.publish(
                PolicyUserEventFactory.toolGovernanceDenied(
                    toolName: name,
                    reason: reason,
                    payloadPreview: preview,
                    correlationId: sessionID
                )
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
                    debugLog("Approval granted for \(name) by \(actor ?? "unknown")")
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
                    debugLog("Approval cancelled for \(name) by \(actor ?? "unknown")")
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
            return MCPToolResult(content: [MCPToolContent.text("Tool client unavailable.")], isError: true)
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
            debugLog("Tool result content: \(Self.debugPayload(result.text))")
        }
        await Self.publishPolicyUserEventIfBlocked(toolName: interceptedEvent.toolName, resultText: result.text)
        return result
    }

    private static func publishPolicyUserEventIfBlocked(toolName: String, resultText: String) async {
        guard toolName == "python_script_exec" else { return }
        guard let data = resultText.data(using: .utf8) else { return }
        guard let payload = try? JSONDecoder().decode(PythonScriptExecutionResult.self, from: data) else { return }

        // Switch only on explicit failureStage — never infer from decision + reviewerAssessment
        // (an allow assessment must not surface as “security review denied”).
        let event: PolicyUserEvent?
        switch payload.failureStage {
        case .none:
            event = nil
        case .staticValidation:
            let findings = payload.validationFindings
            event = PolicyUserEventFactory.staticValidationDenied(
                findings: findings.isEmpty ? ["The request was blocked by static policy checks."] : findings,
                toolName: toolName,
                scriptPreview: nil
            )
        case .llmReview:
            if let assessment = payload.reviewerAssessment,
               assessment.suggestedAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "deny"
                || assessment.alignedWithRequest == false {
                event = PolicyUserEventFactory.reviewerDenied(
                    summary: assessment.summary,
                    concerns: assessment.concerns,
                    toolName: toolName
                )
            } else {
                // Reviewer missing/failed/error findings — not soft allow concerns.
                let findings = payload.validationFindings
                event = PolicyUserEventFactory.reviewerDenied(
                    summary: findings.first ?? "Security review could not approve this request.",
                    concerns: findings,
                    toolName: toolName
                )
            }
        case .execution:
            event = PolicyUserEventFactory.scriptExecutionFailed(
                exitCode: payload.exitCode,
                stderr: payload.stderr,
                toolName: toolName
            )
        case .timeout:
            event = PolicyUserEventFactory.scriptExecutionTimedOut(toolName: toolName)
        case .egress:
            let detail = [payload.stderr, payload.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            event = PolicyUserEventFactory.egressDenied(detail: detail, toolName: toolName)
        }

        if let event {
            await AppEventBus.shared.publish(event)
        }
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
                    named: invocation.toolName,
                    arguments: invocation.arguments,
                    sessionID: sessionID,
                    interceptor: interceptor,
                    approvalPresenter: approvalPresenter
                )
                results.append(result)
            } catch MCPClientError.toolExecutionDenied(let toolName, let reason) {
                results.append(MCPToolResult(content: [MCPToolContent.text("\(toolName) \(reason)")], isError: true))
            }
        }

        let hasErrors = results.contains(where: \.isError)
        return MCPToolBatchResult(
            results: results,
            combinedContent: results.map(\.text).joined(separator: "\n"),
            isError: hasErrors
        )
    }

    private func makeToolInterceptor(override: ToolRequestInterceptor?) -> ToolRequestInterceptor {
        if let override {
            return override
        }
        if let policyStore {
            let policy = StoreBackedToolGovernancePolicy(store: policyStore, applicationName: applicationName)
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
    
    private static func debugPayload(_ payload: String, limit: Int = 12_000) -> String {
        if isJSONObjectOrArray(payload) {
            return prettifyJSON(payload) ?? payload
        }
        
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
