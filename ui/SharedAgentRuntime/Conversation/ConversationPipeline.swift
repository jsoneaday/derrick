import Foundation
import LLMAgentClient
import MCP
import MCPClient

protocol ConversationStreamingClient: Sendable {
    associatedtype Model: AgentModel

    func stream(_ request: AgentRequest, model: Model) -> AsyncThrowingStream<AgentStreamEvent, Error>
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
                    let toolCatalog = try await toolCatalogContext()
                    let request = AgentRequest.prompt(prompt, system: systemPrompt(from: retrieval, toolCatalog: toolCatalog))
                    let upstream = client.stream(request, model: model)
                    var completion = ""

                    for try await event in upstream {
                        guard case .text(let chunk) = event else { continue }
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

            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    task.cancel()
                }
            }
        }
    }

    func systemPrompt(from memoryContext: String, toolCatalog: String = "") -> String {
        let trimmed = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let memoryBlock = trimmed.isEmpty
            ? "Retrieved session memory: none."
            : ["Retrieved session memory:", trimmed].joined(separator: "\n\n")

        var sections: [String] = [ragInstructions, memoryBlock]
        let toolCatalog = toolCatalog.trimmingCharacters(in: .whitespacesAndNewlines)
        if !toolCatalog.isEmpty {
            sections.append(toolCatalog)
        }
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

    func toolCatalogContext() async throws -> String {
        guard let mcpClient else {
            throw ConversationPipelineError.toolCatalogUnavailable("No tool client configured.")
        }

        await MainActor.run {
            debugLog("Loading tool catalog…")
        }
        let tools = try await mcpClient.searchTools(matching: "")
        guard !tools.isEmpty else {
            throw ConversationPipelineError.toolCatalogUnavailable("Tool catalog empty (MCP mesh or agents host).")
        }
        await MainActor.run {
            debugLog("Tool catalog loaded: \(tools.map(\.name).joined(separator: ", "))")
        }

        let lines = tools.map { tool in
            let description = tool.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No description."
            let schema = tool.inputSchema.map { Self.describe(value: $0) } ?? "{}"
            return "- \(tool.name): \(description)\n  input_schema: \(schema)"
        }
        return "Available MCP tools:\n" + lines.joined(separator: "\n")
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
            return "\"\(string)\""
        case .data(_, let data):
            return "\"\(data.base64EncodedString())\""
        case .array(let array):
            return "[" + array.map(describe(value:)).joined(separator: ", ") + "]"
        case .object(let object):
            let pairs = object.keys.sorted().map { key in
                "\"\(key)\": \(describe(value: object[key] ?? .null))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        }
    }
}

enum ConversationPipelineError: Error, LocalizedError {
    case toolCatalogUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .toolCatalogUnavailable(let message):
            return message
        }
    }
}
