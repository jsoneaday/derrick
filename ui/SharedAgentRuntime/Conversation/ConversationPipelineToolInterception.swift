import Foundation
import MCP
import MCPClient
import MemorySystem
import PolicyRuntime
import Lib
import MCPServer
import AppEvents
import PolicyUserInteraction
import LLMAgentClient

extension ConversationPipeline {
    func callToolWithPolicyInterception(
        named name: String,
        arguments: [String: Value],
        sessionID: String,
        userPrompt: String? = nil,
        interceptor: ToolRequestInterceptor? = nil,
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil
    ) async throws -> MCPToolResult {
        let toolOverallStarted = Date()
        await MainActor.run {
            debugLog("Tool request given: \(name)")
        }
        // Models often omit user_prompt; inject conversation prompt so the security reviewer
        // can align script intent (empty prompt → false deny on intent checks).
        var arguments = arguments
        if name == "python_script_exec" {
            let existing = arguments["user_prompt"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existing.isEmpty,
               let userPrompt,
               !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                arguments["user_prompt"] = .string(userPrompt)
            }
        }
        let encodeStarted = Date()
        let event = ToolInvocationEvent(
            sessionID: sessionID,
            toolName: name,
            argumentsJSON: try toolArgumentsToJSON(arguments)
        )
        let encodeMS = PipelineTiming.elapsedMS(from: encodeStarted)
        await MainActor.run {
            debugLog("Tool request JSON: \(Self.debugPayload(event.argumentsJSON))")
        }

        let effectiveInterceptor = makeToolInterceptor(override: interceptor)
        await MainActor.run {
            debugLog("Policy rule processing: evaluating \(name)")
        }

        do {
            let confirmMSBox = TimingAccumulator()
            let proceedMSBox = TimingAccumulator()
            let result = try await effectiveInterceptor.interceptAndRun(
                event,
                confirm: { [self] confirmEvent, requiredFields in
                    let confirmStarted = Date()
                    defer { confirmMSBox.add(PipelineTiming.elapsedMS(from: confirmStarted)) }
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
                        return .approved(
                            ToolInvocationEvent(
                                sessionID: confirmEvent.sessionID,
                                toolName: confirmEvent.toolName,
                                argumentsJSON: editedArgumentsJSON,
                                timestamp: confirmEvent.timestamp
                            )
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
                        return .cancelled(actor: actor)
                    }
                },
                proceed: { [self] interceptedEvent in
                    let proceedStarted = Date()
                    defer { proceedMSBox.add(PipelineTiming.elapsedMS(from: proceedStarted)) }
                    await MainActor.run {
                        debugLog("Policy decision: allow \(interceptedEvent.toolName)")
                    }
                    let interceptedArguments = try toolArgumentsFromJSON(interceptedEvent.argumentsJSON)
                    guard let mcpClient else {
                        return MCPToolResult(content: [MCPToolContent.text("Tool client unavailable.")], isError: true)
                    }
                    if interceptedEvent.toolName == "python_script_exec" {
                        let pythonAllowed = await UsageLimitsService.shared.allowPythonScriptRun()
                        if !pythonAllowed {
                            throw MCPClientError.toolExecutionDenied(
                                toolName: interceptedEvent.toolName,
                                reason: "Usage limit: max python_script_exec runs for this message."
                            )
                        }
                        let allowNetwork = Self.boolArgument(interceptedArguments, key: "allow_network")
                        if allowNetwork {
                            let reviewerAllowed = await UsageLimitsService.shared.allowReviewerCall()
                            if !reviewerAllowed {
                                throw MCPClientError.toolExecutionDenied(
                                    toolName: interceptedEvent.toolName,
                                    reason: "Usage limit: max security reviewer calls for this message."
                                )
                            }
                        }
                        // Preflight before MCPService/docker: extract hosts, allowlist, reverse-XPC prompt.
                        // Mid-flight egress remains a backstop for hosts not present in the script text.
                        let script = interceptedArguments["script"]?.stringValue ?? ""
                        if let blockedJSON = await EgressAllowlistService.shared.preflightPythonScriptNetwork(
                            script: script,
                            allowNetwork: allowNetwork
                        ) {
                            await MainActor.run {
                                debugLog("Egress preflight blocked \(interceptedEvent.toolName) before MCPService")
                            }
                            return MCPToolResult(content: [.text(blockedJSON)], isError: true)
                        }
                    }
                    await MainActor.run {
                        debugLog("Executing tool: \(interceptedEvent.toolName)")
                    }
                    let execStarted = Date()
                    let result = try await mcpClient.callTool(
                        named: interceptedEvent.toolName,
                        arguments: interceptedArguments
                    )
                    let mcpCallMS = PipelineTiming.elapsedMS(from: execStarted)
                    PipelineTiming.log(
                        "tool=\(interceptedEvent.toolName) mcp_call_ms=\(mcpCallMS) isError=\(result.isError) result_chars=\(result.text.utf8.count)"
                    )
                    // Attribute reviewer-ish tokens from phase timing when present.
                    if interceptedEvent.toolName == "python_script_exec" {
                        await Self.recordReviewerTokensIfPresent(resultText: result.text)
                    }
                    await MainActor.run {
                        debugLog("Tool result: \(interceptedEvent.toolName) (isError=\(result.isError))")
                        debugLog("Tool result content: \(Self.debugPayload(result.text))")
                    }
                    await Self.publishPolicyUserEventIfBlocked(
                        toolName: interceptedEvent.toolName,
                        resultText: result.text
                    )
                    await Self.publishJobSchedulingFailureIfNeeded(
                        toolName: interceptedEvent.toolName,
                        resultText: result.text,
                        sessionID: sessionID
                    )
                    return result
                }
            )
            PipelineTiming.log(
                "tool=\(name) encode_ms=\(encodeMS) confirm_ms=\(confirmMSBox.total) proceed_ms=\(proceedMSBox.total) total_ms=\(PipelineTiming.elapsedMS(from: toolOverallStarted))"
            )
            return result
        } catch ToolInvocationInterceptionError.denied(let reason) {
            PipelineTiming.log(
                "tool=\(name) denied encode_ms=\(encodeMS) total_ms=\(PipelineTiming.elapsedMS(from: toolOverallStarted)) reason=\(reason)"
            )
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
            await PolicyDecisionRouting.publishNotice(
                PolicyUserEventFactory.toolGovernanceDenied(
                    toolName: name,
                    reason: reason,
                    payloadPreview: preview,
                    correlationId: sessionID
                )
            )
            throw MCPClientError.toolExecutionDenied(toolName: name, reason: reason)
        } catch ToolInvocationInterceptionError.cancelled(let reason) {
            PipelineTiming.log(
                "tool=\(name) cancelled encode_ms=\(encodeMS) total_ms=\(PipelineTiming.elapsedMS(from: toolOverallStarted)) reason=\(reason)"
            )
            throw MCPClientError.toolExecutionDenied(toolName: name, reason: reason)
        }
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
        case .containerLease:
            let detail = payload.validationFindings.joined(separator: "\n")
            event = PolicyUserEventFactory.scriptExecutionContainerLeaseExceeded(
                detail: detail.isEmpty ? nil : detail,
                toolName: toolName
            )
        case .egress:
            let detailFromIO = [payload.stderr, payload.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let detail = detailFromIO.isEmpty
                ? payload.validationFindings.joined(separator: "\n")
                : detailFromIO
            event = PolicyUserEventFactory.egressDenied(detail: detail, toolName: toolName)
        }

        if let event {
            await PolicyDecisionRouting.publishNotice(event)
        }
    }

    private static func publishJobSchedulingFailureIfNeeded(
        toolName: String,
        resultText: String,
        sessionID: String
    ) async {
        guard toolName == "jobs_create" || toolName == "jobs_schedule_create" else { return }
        let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains("\"ok\":true") || trimmed.contains("\"ok\": true") {
            return
        }
        let detail = trimmed.count > 800 ? String(trimmed.prefix(800)) + "…" : trimmed
        await PolicyDecisionRouting.publishNotice(
            PolicyUserEventFactory.jobSchedulingFailed(
                toolName: toolName,
                reason: "The job could not be scheduled.",
                detail: detail,
                correlationId: sessionID
            )
        )
    }

    func batchCallToolsWithPolicyInterception(
        _ request: MCPToolBatchRequest,
        sessionID: String,
        userPrompt: String? = nil,
        interceptor: ToolRequestInterceptor? = nil,
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil
    ) async throws -> MCPToolBatchResult {
        // MA-3: run independent batch invocations concurrently (order of results preserved).
        let count = request.invocations.count
        guard count > 0 else {
            return MCPToolBatchResult(results: [], combinedContent: "", isError: false)
        }

        let results: [MCPToolResult] = await withTaskGroup(of: (Int, MCPToolResult).self) { group in
            for (index, invocation) in request.invocations.enumerated() {
                group.addTask {
                    do {
                        let result = try await self.callToolWithPolicyInterception(
                            named: invocation.toolName,
                            arguments: invocation.arguments,
                            sessionID: sessionID,
                            userPrompt: userPrompt,
                            interceptor: interceptor,
                            approvalPresenter: approvalPresenter
                        )
                        return (index, result)
                    } catch MCPClientError.toolExecutionDenied(let toolName, let reason) {
                        return (
                            index,
                            MCPToolResult(content: [MCPToolContent.text("\(toolName) \(reason)")], isError: true)
                        )
                    } catch {
                        return (
                            index,
                            MCPToolResult(
                                content: [MCPToolContent.text(error.localizedDescription)],
                                isError: true
                            )
                        )
                    }
                }
            }
            var ordered = Array<MCPToolResult?>(repeating: nil, count: count)
            for await (index, result) in group {
                ordered[index] = result
            }
            return ordered.compactMap { $0 }
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

    private static func boolArgument(_ arguments: [String: Value], key: String) -> Bool {
        guard let value = arguments[key] else { return false }
        switch value {
        case .bool(let b): return b
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t == "true" || t == "1" || t == "yes"
        case .int(let i): return i != 0
        default: return false
        }
    }

    private static func recordReviewerTokensIfPresent(resultText: String) async {
        guard let data = resultText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timing = obj["phaseTiming"] as? [String: Any]
        else { return }
        // Prefer explicit API usage if the tool ever embeds it; else char-based estimate for reviewer I/O.
        if let prompt = timing["reviewerPromptTokens"] as? Int,
           let completion = timing["reviewerCompletionTokens"] as? Int {
            let usage = AgentTokenUsage(
                promptTokens: prompt,
                completionTokens: completion,
                source: .providerAPI
            )
            _ = await UsageLimitsService.shared.recordAPIUsage(usage)
            return
        }
        let req = timing["reviewerRequestChars"] as? Int ?? 0
        let res = timing["reviewerResponseChars"] as? Int ?? 0
        let usage = AgentTokenUsage(
            promptTokens: max(0, (req + 3) / 4),
            completionTokens: max(0, (res + 3) / 4),
            source: .estimated
        )
        guard usage.totalTokens > 0 else { return }
        _ = await UsageLimitsService.shared.recordAPIUsage(usage)
    }
}

/// Thread-safe cumulative ms for nested async tool timing.
private final class TimingAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func add(_ ms: Int) {
        lock.lock()
        value += max(0, ms)
        lock.unlock()
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
