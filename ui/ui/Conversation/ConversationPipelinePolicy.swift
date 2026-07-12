import Foundation
import LLMAgentClient
import MCP
import MCPClient
import MemorySystem

extension ConversationPipeline {
    func streamWithPolicyInterception(
        prompt: String,
        sessionID: String,
        parentAgentID: String? = nil,
        toolCalls: [ToolCallRecord] = [],
        scope: MemoryAccessibility = .private,
        interceptor: PolicyInterceptor = DefaultPolicyInterceptor(),
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil
    ) async -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var workingPrompt = prompt
                    var aggregatedToolCalls = toolCalls
                    let maxToolRounds = 3
                    let requiresCurrentInfoTool = Self.requiresCurrentInfoTool(prompt)

                    for round in 0...maxToolRounds {
                        await MainActor.run {
                            debugLog("Prompt sent (round \(round + 1)): \(workingPrompt.prefix(120))")
                        }
                        let retrieval = (try? await retrieveMemoryContext(for: workingPrompt)) ?? ""
                        let toolCatalog = await toolCatalogContext()
                        let request = AgentRequest.prompt(workingPrompt, system: systemPrompt(from: retrieval, toolCatalog: toolCatalog))
                        await MainActor.run {
                            debugLog(Self.formatLLMRequest(request, round: round + 1))
                        }
                        let upstream = client.stream(request, model: model)
                        var completion = ""
                        var chunkIndex = 0
                        var streamingState = ToolProbeStreamingState.undecided(buffer: "")
                        var streamedVisibleContent = false

                        for try await chunk in upstream {
                            let event = AssistantChunkEvent(
                                sessionID: sessionID,
                                chunkIndex: chunkIndex,
                                content: chunk
                            )

                            if let interceptedContent = try await interceptor.interceptAssistantChunk(event) {
                                completion += interceptedContent
                                chunkIndex += 1
                                switch streamingState {
                                case .toolRequest:
                                    break
                                case .prose:
                                    if !requiresCurrentInfoTool || !aggregatedToolCalls.isEmpty {
                                        streamedVisibleContent = true
                                        continuation.yield(interceptedContent)
                                    }
                                case .undecided(let buffer):
                                    let merged = buffer + interceptedContent
                                    switch Self.classifyStreamingPrefix(merged) {
                                    case .toolRequest:
                                        streamingState = .toolRequest
                                    case .prose(let prefix):
                                        streamingState = .prose(prefix: "")
                                        if (!requiresCurrentInfoTool || !aggregatedToolCalls.isEmpty), !prefix.isEmpty {
                                            streamedVisibleContent = true
                                            continuation.yield(prefix)
                                        }
                                    case .undecided:
                                        streamingState = .undecided(buffer: merged)
                                    }
                                }
                            }
                        }

                        guard !completion.isEmpty else {
                            break
                        }
                        await MainActor.run {
                            debugLog("LLM completion received (round \(round + 1), chunks=\(chunkIndex))")
                            debugLog(Self.formatLLMResponse(completion, round: round + 1))
                        }

                        let completionEvent = AssistantCompletionEvent(
                            sessionID: sessionID,
                            fullCompletion: completion,
                            chunkCount: chunkIndex
                        )
                        guard let interceptedCompletion = try await interceptor.interceptAssistantCompletion(completionEvent) else {
                            await MainActor.run {
                                debugLog("Completion blocked by policy engine")
                            }
                            break
                        }
                        await MainActor.run {
                            debugLog("Completion validated by policy engine")
                        }
                        let typedCompletion = Self.typedCompletion(from: interceptedCompletion)
                        await MainActor.run {
                            debugLog("Declared message type: \(typedCompletion.debugName)")
                        }

                        if case .toolRequest(let payload) = typedCompletion,
                           let parsedToolRequest = Self.parseToolPayload(payload),
                           round < maxToolRounds {
                            await MainActor.run {
                                debugLog("Tool request detected; forwarding to policy engine")
                            }
                            let toolExecution = try await executeToolRequest(
                                parsedToolRequest,
                                sessionID: sessionID,
                                approvalPresenter: approvalPresenter
                            )
                            aggregatedToolCalls.append(contentsOf: toolExecution.records)
                            await MainActor.run {
                                debugLog("Tool result received")
                            }

                            workingPrompt = Self.buildFollowUpPrompt(
                                originalPrompt: prompt,
                                assistantToolRequest: payload,
                                toolResultSummary: toolExecution.summary
                            )
                            continue
                        }

                        if case .toolRequest = typedCompletion {
                            await MainActor.run {
                                debugLog("Tool request payload failed strict schema validation")
                            }
                            continue
                        }

                        if requiresCurrentInfoTool, aggregatedToolCalls.isEmpty, round < maxToolRounds {
                            await MainActor.run {
                                debugLog("Current-info request answered without tool; forcing tool_request retry")
                            }
                            workingPrompt = Self.buildForcedToolPrompt(originalPrompt: prompt)
                            continue
                        }

                        let displayCompletion = typedCompletion.displayContent
                        if !streamedVisibleContent {
                            continuation.yield(displayCompletion)
                        }

                        try? await memoryCoordinator.ingest(
                            MemoryIngestInput(
                                sessionKey: sessionKey,
                                parentAgentID: parentAgentID,
                                prompt: prompt,
                                completion: displayCompletion,
                                toolCalls: aggregatedToolCalls,
                                scope: scope
                            )
                        )
                        break
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func formatLLMRequest(_ request: AgentRequest, round: Int) -> String {
        let messages = request.messages.enumerated().map { index, message in
            "[\(index)] \(message.role.rawValue):\n\(preview(message.content))"
        }
        return "LLM request (round \(round)):\n" + messages.joined(separator: "\n\n")
    }

    private static func preview(_ content: String) -> String {
        guard content.count > 40 else {
            return content
        }
        return String(content.prefix(37)) + "..."
    }

    private static func formatLLMResponse(_ completion: String, round: Int) -> String {
        "LLM response (round \(round)):\n\(completion)"
    }

    private func executeToolRequest(
        _ request: ParsedToolRequest,
        sessionID: String,
        approvalPresenter: (any ApprovalConfirmationPresenting)?
    ) async throws -> (summary: String, records: [ToolCallRecord]) {
        switch request {
        case .single(let name, let arguments):
            let result = try await callToolWithPolicyInterception(
                named: name,
                arguments: arguments,
                sessionID: sessionID,
                approvalPresenter: approvalPresenter
            )
            let record = ToolCallRecord(
                name: name,
                arguments: Self.toolCallRecordArguments(from: arguments),
                result: result.content
            )
            let summary = "\(name): \(result.content)"
            return (summary, [record])
        case .batch(let batchRequest):
            let batchResult = try await batchCallToolsWithPolicyInterception(
                batchRequest,
                sessionID: sessionID,
                approvalPresenter: approvalPresenter
            )
            let records = zip(batchRequest.invocations, batchResult.results).map { invocation, result in
                ToolCallRecord(
                    name: invocation.name,
                    arguments: Self.toolCallRecordArguments(from: invocation.arguments),
                    result: result.content
                )
            }
            return (batchResult.combinedContent, records)
        }
    }

    private static func classifyStreamingPrefix(_ text: String) -> ToolProbeStreamingState {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .undecided(buffer: text)
        }

        if let envelope = typedCompletionIfHeaderComplete(from: text) {
            switch envelope {
            case .toolRequest:
                return .toolRequest
            case .assistantResponse(let content), .untyped(let content):
                return .prose(prefix: content)
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if "message_type:".hasPrefix(trimmed.lowercased()) || trimmed.lowercased().hasPrefix("message_type:") {
            return .undecided(buffer: text)
        }

        return .prose(prefix: text)
    }

    private static func parseToolPayload(_ payload: String) -> ParsedToolRequest? {
        guard let data = payload.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            return nil
        }

        if let batch = try? JSONDecoder().decode(MCPToolBatchRequest.self, from: data),
           !batch.invocations.isEmpty {
            return .batch(batch)
        }

        if let single = try? JSONDecoder().decode(SingleToolRequest.self, from: data),
           !single.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .single(name: single.name, arguments: single.arguments ?? [:])
        }

        return nil
    }

    private static func typedCompletion(from text: String) -> TypedCompletion {
        typedCompletionIfHeaderComplete(from: text) ?? .untyped(text)
    }

    private static func typedCompletionIfHeaderComplete(from text: String) -> TypedCompletion? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let firstLineEnd = normalized.firstIndex(of: "\n") else {
            return nil
        }

        let firstLine = normalized[..<firstLineEnd].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard firstLine.hasPrefix("message_type:") else {
            return .untyped(text)
        }

        let rawType = firstLine.dropFirst("message_type:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        var contentStart = normalized.index(after: firstLineEnd)
        if contentStart < normalized.endIndex, normalized[contentStart] == "\n" {
            contentStart = normalized.index(after: contentStart)
        }
        let content = String(normalized[contentStart...])

        switch rawType {
        case "tool_request":
            return .toolRequest(payload: content)
        case "assistant_response":
            return .assistantResponse(content)
        default:
            return .untyped(text)
        }
    }

    private static func buildFollowUpPrompt(
        originalPrompt: String,
        assistantToolRequest: String,
        toolResultSummary: String
    ) -> String {
        """
        Original user prompt:
        \(originalPrompt)

        You requested the following tool call:
        \(assistantToolRequest)

        Tool execution result:
        \(toolResultSummary)

        Produce the final user-facing response using the tool execution result as authoritative.
        Do not say you cannot fetch live data if the tool result contains live data.
        Do not ask the user whether to run a command that has already run.
        When presenting a list of choices, options, steps, items, or alternative paths to the user, ALWAYS format them as a clean Markdown bulleted list (using `-` or `*`) or a numbered list (using `1.`, `2.`), instead of writing them as plain paragraphs.
        Start with `message_type: assistant_response`, followed by a blank line, then the answer.
        """
    }

    private static func buildForcedToolPrompt(originalPrompt: String) -> String {
        """
        The user asked for current/latest information:
        \(originalPrompt)

        You must not answer from model memory. Emit exactly:
        message_type: tool_request

        followed by a strict JSON tool payload using python_script_exec:
        {"name":"python_script_exec","arguments":{...}}

        Use readonly mode, allow_network=true, and fetch authoritative current sources relevant to the request.
        """
    }

    private static func requiresCurrentInfoTool(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        let triggers = [
            "latest",
            "current",
            "recent",
            "up-to-date",
            "up to date",
            "live",
            "release notes",
            "changelog",
            "new features",
            "what are the new",
            "production"
        ]
        return triggers.contains { lowered.contains($0) }
    }

    private static func toolCallRecordArguments(from arguments: [String: Value]) -> [String: String] {
        var mapped: [String: String] = [:]
        for (key, value) in arguments {
            mapped[key] = describe(value: value)
        }
        return mapped
    }

    private static func describe(value: Value) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let bool):
            return bool ? "true" : "false"
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .string(let string):
            return string
        case .data(_, let data):
            return data.base64EncodedString()
        case .array(let array):
            return "[" + array.map(describe(value:)).joined(separator: ", ") + "]"
        case .object(let object):
            let pairs = object.keys.sorted().map { key in
                "\(key): \(describe(value: object[key] ?? .null))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        }
    }
}

private enum ParsedToolRequest {
    case single(name: String, arguments: [String: Value])
    case batch(MCPToolBatchRequest)
}

private struct SingleToolRequest: Decodable {
    let name: String
    let arguments: [String: Value]?
}

private enum TypedCompletion {
    case assistantResponse(String)
    case toolRequest(payload: String)
    case untyped(String)

    var debugName: String {
        switch self {
        case .assistantResponse:
            return "assistant_response"
        case .toolRequest:
            return "tool_request"
        case .untyped:
            return "untyped"
        }
    }

    var displayContent: String {
        switch self {
        case .assistantResponse(let content), .untyped(let content):
            return content
        case .toolRequest:
            return ""
        }
    }
}

private enum ToolProbeStreamingState {
    case undecided(buffer: String)
    case toolRequest
    case prose(prefix: String)
}
