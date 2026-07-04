import Foundation
import LLMAgentClient
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
        _ = approvalPresenter
        let retrieval = (try? await retrieveMemoryContext(for: prompt)) ?? ""

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = AgentRequest.prompt(prompt, system: systemPrompt(from: retrieval))
                    let upstream = client.stream(request, model: model)
                    var completion = ""
                    var chunkIndex = 0

                    for try await chunk in upstream {
                        let event = AssistantChunkEvent(
                            sessionID: sessionID,
                            chunkIndex: chunkIndex,
                            content: chunk
                        )

                        if let interceptedContent = try await interceptor.interceptAssistantChunk(event) {
                            completion += interceptedContent
                            chunkIndex += 1

                            let yieldEvent = PolicyInterceptionEvent.assistantChunk(
                                AssistantChunkEvent(
                                    sessionID: sessionID,
                                    chunkIndex: chunkIndex,
                                    content: interceptedContent
                                )
                            )
                            if case .assistantChunk(let chunkEvent) = yieldEvent {
                                continuation.yield(chunkEvent.content)
                            }
                        }
                    }

                    if !completion.isEmpty {
                        let completionEvent = AssistantCompletionEvent(
                            sessionID: sessionID,
                            fullCompletion: completion,
                            chunkCount: chunkIndex
                        )

                        if let interceptedCompletion = try await interceptor.interceptAssistantCompletion(completionEvent) {
                            try? await memoryCoordinator.ingest(
                                MemoryIngestInput(
                                    sessionKey: sessionKey,
                                    parentAgentID: parentAgentID,
                                    prompt: prompt,
                                    completion: interceptedCompletion,
                                    toolCalls: toolCalls,
                                    scope: scope
                                )
                            )

                            let finalEvent = PolicyInterceptionEvent.assistantCompletion(
                                AssistantCompletionEvent(
                                    sessionID: sessionID,
                                    fullCompletion: interceptedCompletion,
                                    chunkCount: chunkIndex
                                )
                            )
                            if case .assistantCompletion = finalEvent {
                                // Completion ingestion already occurred; chunks were streamed above.
                            }
                        }
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
}
