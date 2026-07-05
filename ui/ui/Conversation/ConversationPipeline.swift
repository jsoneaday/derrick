import Foundation
import LLMAgentClient
import MCP
import MCPClient

protocol ConversationStreamingClient: Sendable {
    associatedtype Model: AgentModel

    func stream(_ request: AgentRequest, model: Model) -> AsyncThrowingStream<String, Error>
}

protocol ConversationToolClient: Sendable {
    func searchTools(matching query: String) async throws -> [MCPToolDescriptor]
    func callTool(named name: String, arguments: [String: Value]) async throws -> MCPToolResult
    func batchCallTools(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult
}

extension AgentClient: ConversationStreamingClient {}
extension MCPClient: ConversationToolClient {}

struct ConversationPipeline<Client: ConversationStreamingClient & Sendable>: Sendable {
    let sessionKey: MemorySessionKey
    let memoryCoordinator: MemoryCoordinator
    let policyStore: (any PolicyStore)?
    let applicationName: String
    let mcpClient: (any ConversationToolClient)?
    let client: Client
    let model: Client.Model
    let ragInstructions: String
    let mcpToolInstructions: String
    let retrievalLimit: Int

    init(
        sessionKey: MemorySessionKey,
        memoryCoordinator: MemoryCoordinator,
        policyStore: (any PolicyStore)? = nil,
        applicationName: String = "ui",
        mcpClient: (any ConversationToolClient)? = nil,
        client: Client,
        model: Client.Model,
        ragInstructions: String,
        mcpToolInstructions: String = "",
        retrievalLimit: Int = 5
    ) {
        self.sessionKey = sessionKey
        self.memoryCoordinator = memoryCoordinator
        self.policyStore = policyStore
        self.applicationName = applicationName
        self.mcpClient = mcpClient
        self.client = client
        self.model = model
        self.ragInstructions = ragInstructions
        self.mcpToolInstructions = mcpToolInstructions
        self.retrievalLimit = retrievalLimit
    }

    func stream(
        prompt: String,
        parentAgentID: String? = nil,
        toolCalls: [ToolCallRecord] = [],
        scope: MemoryAccessibility = .private
    ) async -> AsyncThrowingStream<String, Error> {
        let retrieval = (try? await retrieveMemoryContext(for: prompt)) ?? ""

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = AgentRequest.prompt(prompt, system: systemPrompt(from: retrieval))
                    let upstream = client.stream(request, model: model)
                    var completion = ""

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

    func systemPrompt(from memoryContext: String) -> String {
        let trimmed = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let memoryBlock = trimmed.isEmpty
            ? "Retrieved session memory: none."
            : ["Retrieved session memory:", trimmed].joined(separator: "\n\n")

        var sections: [String] = [ragInstructions, memoryBlock]
        let toolInstructions = mcpToolInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !toolInstructions.isEmpty {
            sections.append(toolInstructions)
        }
        return sections.joined(separator: "\n\n")
    }

    func retrieveMemoryContext(for prompt: String) async throws -> String {
        let retrieval = try await memoryCoordinator.retrieve(
            MemoryRetrievalRequest(
                sessionKey: sessionKey,
                query: prompt,
                limit: retrievalLimit,
                idealTokenCount: model.maxIdealContextTokens,
                maxSupportedTokenCount: model.maxSupportedContextTokens
            )
        )
        return retrieval.context
    }
}
