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

                    for round in 0...maxToolRounds {
                        let retrieval = (try? await retrieveMemoryContext(for: workingPrompt)) ?? ""
                        let request = AgentRequest.prompt(workingPrompt, system: systemPrompt(from: retrieval))
                        let upstream = client.stream(request, model: model)
                        var completion = ""
                        var chunkIndex = 0
                        var suppressStreaming = false

                        for try await chunk in upstream {
                            let event = AssistantChunkEvent(
                                sessionID: sessionID,
                                chunkIndex: chunkIndex,
                                content: chunk
                            )

                            if let interceptedContent = try await interceptor.interceptAssistantChunk(event) {
                                completion += interceptedContent
                                chunkIndex += 1
                                if suppressStreaming {
                                    continue
                                }
                                if Self.isToolRequestPrefix(completion) {
                                    suppressStreaming = true
                                    continue
                                }
                                continuation.yield(interceptedContent)
                            }
                        }

                        guard !completion.isEmpty else {
                            break
                        }

                        let completionEvent = AssistantCompletionEvent(
                            sessionID: sessionID,
                            fullCompletion: completion,
                            chunkCount: chunkIndex
                        )
                        guard let interceptedCompletion = try await interceptor.interceptAssistantCompletion(completionEvent) else {
                            break
                        }

                        if let parsedToolRequest = Self.parseToolRequest(from: interceptedCompletion), round < maxToolRounds {
                            let toolExecution = try await executeToolRequest(
                                parsedToolRequest,
                                sessionID: sessionID,
                                approvalPresenter: approvalPresenter
                            )
                            aggregatedToolCalls.append(contentsOf: toolExecution.records)

                            workingPrompt = Self.buildFollowUpPrompt(
                                originalPrompt: prompt,
                                assistantToolRequest: interceptedCompletion,
                                toolResultSummary: toolExecution.summary
                            )
                            continue
                        }

                        if suppressStreaming {
                            continuation.yield(interceptedCompletion)
                        }

                        try? await memoryCoordinator.ingest(
                            MemoryIngestInput(
                                sessionKey: sessionKey,
                                parentAgentID: parentAgentID,
                                prompt: prompt,
                                completion: interceptedCompletion,
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

    private static func parseToolRequest(from text: String) -> ParsedToolRequest? {
        let normalized = normalizeJSONPayload(text)
        guard let data = normalized.data(using: .utf8) else {
            return nil
        }

        if let single = try? JSONDecoder().decode(SingleToolRequest.self, from: data) {
            return .single(name: single.name, arguments: single.arguments ?? [:])
        }

        if let wrapped = try? JSONDecoder().decode(WrappedSingleToolRequest.self, from: data) {
            return .single(name: wrapped.tool.name, arguments: wrapped.tool.arguments ?? [:])
        }

        if let batch = try? JSONDecoder().decode(MCPToolBatchRequest.self, from: data),
           !batch.invocations.isEmpty {
            return .batch(batch)
        }

        return nil
    }

    private static func isToolRequestPrefix(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{\"name\"") || trimmed.hasPrefix("{\"tool\"") || trimmed.hasPrefix("{\"invocations\"") {
            return true
        }
        if trimmed.hasPrefix("{"),
           trimmed.contains("\"name\""),
           (trimmed.contains("\"arguments\"") || trimmed.contains("\"invocations\"")) {
            return true
        }
        return false
    }

    private static func normalizeJSONPayload(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"), let start = trimmed.range(of: "{"), let end = trimmed.range(of: "}", options: .backwards), start.lowerBound < end.upperBound {
            return String(trimmed[start.lowerBound..<end.upperBound])
        }
        return trimmed
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

        Continue and produce the final user-facing response.
        """
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

private struct WrappedSingleToolRequest: Decodable {
    let tool: SingleToolRequest
}
