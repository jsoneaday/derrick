import Foundation
import LLMAgentClient

protocol ConversationStreamingClient: Sendable {
    associatedtype Model: AgentModel

    func stream(_ request: AgentRequest, model: Model) -> AsyncThrowingStream<String, Error>
}

extension AgentClient: ConversationStreamingClient {}

struct ConversationPipeline<Client: ConversationStreamingClient & Sendable>: Sendable {
    let sessionKey: MemorySessionKey
    let memoryCoordinator: MemoryCoordinator
    let client: Client
    let model: Client.Model
    let retrievalLimit: Int

    init(
        sessionKey: MemorySessionKey,
        memoryCoordinator: MemoryCoordinator,
        client: Client,
        model: Client.Model,
        retrievalLimit: Int = 5
    ) {
        self.sessionKey = sessionKey
        self.memoryCoordinator = memoryCoordinator
        self.client = client
        self.model = model
        self.retrievalLimit = retrievalLimit
    }

    func stream(
        prompt: String,
        parentAgentID: String? = nil,
        toolCalls: [ToolCallRecord] = [],
        scope: MemoryScope = .private
    ) async -> AsyncThrowingStream<String, Error> {
        let retrieval = (try? await memoryCoordinator.retrieve(
            MemoryRetrievalRequest(
                sessionKey: sessionKey,
                query: prompt,
                limit: retrievalLimit
            )
        )) ?? MemoryRetrievalResult(entries: [], context: "", estimatedTokenCount: 0)

        let request = AgentRequest.prompt(prompt, system: systemPrompt(from: retrieval.context))
        let upstream = client.stream(request, model: model)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var completion = ""

                do {
                    for try await chunk in upstream {
                        completion += chunk
                        continuation.yield(chunk)
                    }

                    if !completion.isEmpty {
                        try? await memoryCoordinator.ingest(
                            MemoryIngestInput(
                                sessionKey: sessionKey,
                                parentAgentID: parentAgentID,
                                prompt: prompt,
                                completion: completion,
                                toolCalls: toolCalls,
                                scope: scope
                            )
                        )
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

    private func systemPrompt(from memoryContext: String) -> String? {
        let trimmed = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return [
            "Relevant memory from this session:",
            trimmed,
            "Use this only when it is relevant to the current prompt."
        ]
        .joined(separator: "\n\n")
    }
}
