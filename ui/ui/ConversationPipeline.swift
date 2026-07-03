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
    let mcpClient: (any ConversationToolClient)?
    let client: Client
    let model: Client.Model
    let ragInstructions: String
    let mcpToolInstructions: String
    let mcpToolLoopInstructions: String
    let retrievalLimit: Int

    init(
        sessionKey: MemorySessionKey,
        memoryCoordinator: MemoryCoordinator,
        mcpClient: (any ConversationToolClient)? = nil,
        client: Client,
        model: Client.Model,
        ragInstructions: String,
        mcpToolInstructions: String = "",
        mcpToolLoopInstructions: String = "",
        retrievalLimit: Int = 5
    ) {
        self.sessionKey = sessionKey
        self.memoryCoordinator = memoryCoordinator
        self.mcpClient = mcpClient
        self.client = client
        self.model = model
        self.ragInstructions = ragInstructions
        self.mcpToolInstructions = mcpToolInstructions
        self.mcpToolLoopInstructions = mcpToolLoopInstructions
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
                    if let toolLoopResponse = try await generateToolLoopResponse(prompt: prompt, memoryContext: retrieval) {
                        if !toolLoopResponse.isEmpty {
                            continuation.yield(toolLoopResponse)
                        }

                        if !toolLoopResponse.isEmpty {
                            try? await memoryCoordinator.ingest(
                                MemoryIngestInput(
                                    sessionKey: sessionKey,
                                    parentAgentID: parentAgentID,
                                    prompt: prompt,
                                    completion: toolLoopResponse,
                                    toolCalls: toolCalls,
                                    scope: scope
                                )
                            )
                        }

                        continuation.finish()
                        return
                    }

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

    private func systemPrompt(from memoryContext: String) -> String {
        let trimmed = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let memoryBlock = trimmed.isEmpty
            ? "Retrieved session memory: none."
            : ["Retrieved session memory:", trimmed].joined(separator: "\n\n")

        return [
            ragInstructions,
            memoryBlock
        ]
        .joined(separator: "\n\n")
    }

    private func retrieveMemoryContext(for prompt: String) async throws -> String {
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

    private func generateToolLoopResponse(prompt: String, memoryContext: String) async throws -> String? {
        guard let mcpClient else {
            return nil
        }

        let toolCatalog = try await availableTools(from: mcpClient)
        guard !toolCatalog.isEmpty else {
            return nil
        }

        let toolSystemPrompt = [
            systemPrompt(from: memoryContext),
            mcpToolInstructions,
            mcpToolLoopInstructions,
            toolCatalogPrompt(from: toolCatalog)
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")

        var messages = [
            AgentMessage(role: .system, content: toolSystemPrompt),
            AgentMessage(role: .user, content: prompt)
        ]   

        for _ in 0..<4 {
            let response = try await completeResponse(messages: messages)
            guard let decision = parseToolLoopDecision(from: response) else {
                return response
            }

            switch decision.action {
            case .final:
                return decision.content ?? response
            case .tools:
                let batchRequest = MCPToolBatchRequest(invocations: decision.invocations ?? [])
                let result = try await mcpClient.batchCallTools(batchRequest)
                messages.append(.init(role: .assistant, content: response))
                messages.append(.init(role: .user, content: toolResultPrompt(from: decision, result: result)))
            }
        }

        return try await completeResponse(messages: messages)
    }

    private func completeResponse(messages: [AgentMessage]) async throws -> String {
        let request = AgentRequest(messages: messages)
        let upstream = client.stream(request, model: model)
        var text = ""
        for try await chunk in upstream {
            text += chunk
        }
        return text
    }

    private func availableTools(from client: any ConversationToolClient) async throws -> [MCPToolDescriptor] {
        let tools = try await client.searchTools(matching: "")
        return tools.filter {
            $0.name != "tool_batch"
        }
    }

    private func toolCatalogPrompt(from tools: [MCPToolDescriptor]) -> String {
        let lines = tools.map { tool in
            var entry = "- \(tool.name)"
            if let description = tool.description, !description.isEmpty {
                entry += "\n  description: \(description)"
            }
            if let schema = tool.inputSchema, let schemaString = encode(schema) {
                entry += "\n  schema: \(schemaString)"
            }
            return entry
        }

        return ["Available MCP tools:", lines.joined(separator: "\n")].joined(separator: "\n\n")
    }

    private func toolResultPrompt(from decision: ToolLoopDecision, result: MCPToolBatchResult) -> String {
        let invocations = decision.invocations ?? []
        let pairs = zip(invocations, result.results).map { invocation, output in
            "- \(invocation.name): \(output.content)"
        }

        return [
            "Tool results:",
            pairs.joined(separator: "\n"),
            "",
            "Combined content:",
            result.combinedContent
        ]
        .joined(separator: "\n")
    }

    private func parseToolLoopDecision(from text: String) -> ToolLoopDecision? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonText.data(using: .utf8),
              let decision = try? JSONDecoder().decode(ToolLoopDecision.self, from: data) else {
            return nil
        }
        return decision
    }

    private func encode(_ value: Value) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct ToolLoopDecision: Decodable {
    enum Action: String, Decodable {
        case final
        case tools
    }

    let action: Action
    let content: String?
    let invocations: [MCPToolInvocation]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Action.self, forKey: .responseType)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        invocations = try container.decodeIfPresent([MCPToolInvocation].self, forKey: .invocations)
    }

    enum CodingKeys: String, CodingKey {
        case responseType = "response_type"
        case content
        case invocations
    }
}

private extension ToolLoopDecision {
    init(action: Action, content: String?, invocations: [MCPToolInvocation]?) {
        self.action = action
        self.content = content
        self.invocations = invocations
    }
}
