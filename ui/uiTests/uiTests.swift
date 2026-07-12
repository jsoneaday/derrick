import Foundation
import LLMAgentClient
import MCP
import Testing
@testable import ui

@Suite struct uiTests {
    @MainActor @Test func dotenvModeBypassesKeychainAndUsesRootUiDotEnv() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let uiFolder = root.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: uiFolder, withIntermediateDirectories: true)
        try "UI_SECRET_MODE=dotenv\nGEMINI_API_KEY=dotenv-gemini\n".write(
            to: uiFolder.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let resolver = AppSecretResolver(
            environment: [:],
            currentDirectoryURL: root,
            bundleURL: root,
            keychainLoader: { _ in "keychain-gemini" }
        )

        #expect(
            resolver.resolve(
                account: "gemini-3.1-flash-lite",
                environmentKeys: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            ) == "dotenv-gemini"
        )
    }

    @MainActor @Test func keychainModeStillPrefersKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let uiFolder = root.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: uiFolder, withIntermediateDirectories: true)
        try "UI_SECRET_MODE=dotenv\nGEMINI_API_KEY=dotenv-gemini\n".write(
            to: uiFolder.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let resolver = AppSecretResolver(
            environment: ["UI_SECRET_MODE": "keychain"],
            currentDirectoryURL: root,
            bundleURL: root,
            keychainLoader: { _ in "keychain-gemini" }
        )

        #expect(
            resolver.resolve(
                account: "gemini-3.1-flash-lite",
                environmentKeys: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            ) == "keychain-gemini"
        )
    }

    @MainActor @Test func secretStoreLoadReturnsNilForMissingItem() throws {
        let store = SecretStore(
            service: "ui-tests-\(UUID().uuidString)",
            account: "missing-\(UUID().uuidString)"
        )

        #expect(try store.load() == nil)
    }

    @Test func llmProviderDefaultsToExpectedModels() {
        #expect(LLMProviderChoice.gemini.defaultModel.displayName == "gemini-3.1-flash-lite")
        #expect(LLMProviderChoice.openai.defaultModel.displayName == "gpt-5-mini")
        #expect(LLMProviderChoice.gemini.apiKeyEnvironmentKeys.contains("GEMINI_API_KEY"))
        #expect(LLMProviderChoice.openai.apiKeyEnvironmentKeys.contains("OPENAI_API_KEY"))
    }

    @Test func debugConfigurationReadsIsDebugFromEnvironment() {
        #expect(AppDebugConfiguration(environment: ["IS_DEBUG": "true"]).isDebugEnabled)
        #expect(AppDebugConfiguration(environment: ["IS_DEBUG": "TRUE"]).isDebugEnabled)
        #expect(!AppDebugConfiguration(environment: ["IS_DEBUG": "false"]).isDebugEnabled)
        #expect(!AppDebugConfiguration(environment: [:]).isDebugEnabled)
    }

    @MainActor @Test func debugConfigurationReadsIsDebugFromResourcesDotEnv() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "IS_DEBUG=true\n".write(
            to: resources.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let configuration = AppDebugConfiguration(
            environment: [:],
            currentDirectoryURL: root,
            bundleURL: root
        )

        #expect(configuration.isDebugEnabled)
    }

    @MainActor @Test func pipelineInjectsRelevantMemoryIntoTheNextPrompt() async throws {
        let sessionKey = MemorySessionKey(sessionID: "session-1", agentID: "agent-ui")
        let summarizer = RecordingSummarizer(
            layer1: MemorySummary(
                text: "Intent: memory planning\nKeywords: memory, session replay",
                metadata: MemorySummaryMetadata(
                    keywords: ["memory", "session replay"],
                    compressionRatio: 0.2,
                    sourceTokenCount: 50,
                    summaryTokenCount: 10
                )
            ),
            layer2: MemorySummary(
                text: "Prompt: Build a memory pipeline.\nCompletion: Use layered summaries and intent keywords.",
                metadata: MemorySummaryMetadata(
                    keywords: ["memory", "summaries", "keywords"],
                    compressionRatio: 0.6,
                    sourceTokenCount: 50,
                    summaryTokenCount: 30
                )
            )
        )
        let store = InMemoryMemoryStore()
        let seedCoordinator = MemoryCoordinator(
            store: store,
            summarizer: summarizer,
            policy: TieredMemoryCompactionPolicy(),
            budget: MemoryBudget(maxTokenCount: 1)
        )
        let coordinator = MemoryCoordinator(
            store: store,
            summarizer: summarizer,
            policy: TieredMemoryCompactionPolicy(),
            budget: MemoryBudget(maxTokenCount: 10_000)
        )

        try await seedCoordinator.ingest(
            MemoryIngestInput(
                sessionKey: sessionKey,
                prompt: "How should I manage memory layers?",
                completion: "Use layered summaries and intent keywords.",
                toolCalls: [ToolCallRecord(name: "summarize_memory", arguments: ["mode": "layered"], result: "done")]
            )
        )

        let client = RecordingClient(chunks: ["Hello", " world"])
        let pipeline = ConversationPipeline(
            sessionKey: sessionKey,
            memoryCoordinator: coordinator,
            client: client,
            model: FakeModel(),
            retrievalLimit: 5
        )

        let stream = await pipeline.stream(prompt: "What should we do next?")
        let response = try await Self.collect(stream)

        #expect(response == "Hello world")
        let capturedRequest = client.lastRequest
        #expect(capturedRequest?.messages.first?.role == .system)
        #expect(capturedRequest?.messages.first?.content.contains("Intent: memory planning") == true)

        let retrieval = try await coordinator.retrieve(
            MemoryRetrievalRequest(sessionKey: sessionKey, query: nil, limit: 10)
        )
        #expect(retrieval.entries.count == 4)
        #expect(retrieval.context.contains("Intent: memory planning") == true)

        let records = await coordinator.records(for: sessionKey)
        #expect(records.count == 1)
        #expect(records.first?.rawPair?.prompt == "What should we do next?")
        #expect(records.first?.rawPair?.completion == "Hello world")
    }

    @MainActor @Test func pipelineDoesNotLeakMemoryAcrossAgentIdentifiers() async throws {
        let sessionID = "shared-session"
        let firstSessionKey = MemorySessionKey(sessionID: sessionID, agentID: "agent-a")
        let secondSessionKey = MemorySessionKey(sessionID: sessionID, agentID: "agent-b")
        let summarizer = RecordingSummarizer(
            layer1: MemorySummary(
                text: "Intent: isolated memory\nKeywords: isolated",
                metadata: MemorySummaryMetadata(
                    keywords: ["isolated"],
                    compressionRatio: 0.25,
                    sourceTokenCount: 40,
                    summaryTokenCount: 10
                )
            ),
            layer2: MemorySummary(
                text: "Prompt: Seed one agent.\nCompletion: This should not leak to the other agent.",
                metadata: MemorySummaryMetadata(
                    keywords: ["isolated"],
                    compressionRatio: 0.5,
                    sourceTokenCount: 40,
                    summaryTokenCount: 20
                )
            )
        )
        let sharedStore = InMemoryMemoryStore()
        let firstCoordinator = MemoryCoordinator(
            store: sharedStore,
            summarizer: summarizer,
            policy: TieredMemoryCompactionPolicy(),
            budget: MemoryBudget(maxTokenCount: 1)
        )
        let secondCoordinator = MemoryCoordinator(
            store: sharedStore,
            summarizer: summarizer,
            policy: TieredMemoryCompactionPolicy(),
            budget: MemoryBudget(maxTokenCount: 10_000)
        )

        try await firstCoordinator.ingest(
            MemoryIngestInput(
                sessionKey: firstSessionKey,
                prompt: "Seed memory for agent A",
                completion: "Store a summary for agent A only."
            )
        )

        let client = RecordingClient(chunks: ["B-only response"])
        let pipeline = ConversationPipeline(
            sessionKey: secondSessionKey,
            memoryCoordinator: secondCoordinator,
            client: client,
            model: FakeModel(),
            retrievalLimit: 5
        )

        let stream = await pipeline.stream(prompt: "Does agent B see agent A's memory?")
        _ = try await Self.collect(stream)

        let capturedRequest = client.lastRequest
        #expect(capturedRequest?.messages.first?.role != .system)
        #expect(capturedRequest?.messages.count == 1)
    }

    @MainActor @Test func debugLogStoreCorrectlyParsesPrewarmingAndCreatingStatus() {
        let store = DebugLogStore.shared
        
        store.log("checking if docker environment needs pre-warming...")
        #expect(store.currentStatus == "Thinking...")
        
        store.log("pre-warming: creating volume 'derrick-pip-cache'...")
        #expect(store.currentStatus == "Setting up container environment...")
        
        store.log("pre-warming: pulling image 'ghcr.io/astral-sh/uv:python3.12-alpine' in background...")
        #expect(store.currentStatus == "Setting up container environment (pulling Docker image)...")
        
        store.log("xpc run request received while script environment is being created.")
        #expect(store.currentStatus == "Setting up container environment (pulling Docker image)...")
    }

    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var output = ""
        for try await chunk in stream {
            output += chunk
        }
        return output
    }
}

private actor RecordingSummarizer: MemorySummarizer {
    let layer1: MemorySummary
    let layer2: MemorySummary
    private(set) var receivedPairs: [PromptResponsePair] = []

    init(layer1: MemorySummary, layer2: MemorySummary) {
        self.layer1 = layer1
        self.layer2 = layer2
    }

    func summarize(_ pair: PromptResponsePair) async throws -> MemorySummaryPair {
        receivedPairs.append(pair)
        return MemorySummaryPair(layer1: layer1, layer2: layer2)
    }
}

private struct FakeModel: AgentModel {
    var id: AgentModelID {
        AgentModelID(provider: "fake", name: "fake")
    }

    var maxSupportedContextTokens: Int {
        100_000
    }

    var maxIdealContextTokens: Int {
        50_000
    }
}

private final class RecordingClient: @unchecked Sendable, ConversationStreamingClient {
    typealias Model = FakeModel

    private let chunks: [String]
    private(set) var lastRequest: AgentRequest?
    private(set) var lastModel: FakeModel?

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func stream(_ request: AgentRequest, model: FakeModel) -> AsyncThrowingStream<String, Error> {
        lastRequest = request
        lastModel = model

        return AsyncThrowingStream { continuation in
            Task {
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }
}

private actor RecordingToolClient: ConversationToolClient {
    private(set) var calledTools: [String] = []
    private(set) var lastBatch: MCPToolBatchRequest?

    func searchTools(matching query: String) async throws -> [MCPToolDescriptor] {
        [
            MCPToolDescriptor(
                name: "tool_search",
                description: "Search tools.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")])
                    ])
                ])
            ),
            MCPToolDescriptor(
                name: "tool",
                description: "Call a tool.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "arguments": .object(["type": .string("object")])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            MCPToolDescriptor(
                name: "session_memory_search",
                description: "Search prior session memory with optional query and paging.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "limit": .object(["type": .string("number")]),
                        "page": .object(["type": .string("number")])
                    ]),
                    "required": .array([.string("limit"), .string("page")])
                ])
            ),
            MCPToolDescriptor(
                name: "echo",
                description: "Echo text.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")])
                ])
            )
        ]
    }

    func callTool(named name: String, arguments: [String : Value]) async throws -> MCPToolResult {
        calledTools.append(name)
        if name == "session_memory_search" {
            return MCPToolResult(content: "")
        }

        if name == "echo" {
            return MCPToolResult(content: arguments["text"]?.stringValue ?? "")
        }

        return MCPToolResult(content: "unknown", isError: true)
    }

    func batchCallTools(_ request: MCPToolBatchRequest) async throws -> MCPToolBatchResult {
        lastBatch = request
        let results = try await request.invocations.map { invocation in
            try await callTool(named: invocation.name, arguments: invocation.arguments)
        }
        return MCPToolBatchResult(
            results: results,
            combinedContent: results.map(\.content).joined(separator: "\n\n"),
            isError: results.contains(where: \.isError)
        )
    }
}

private final class ScriptedStreamingClient: @unchecked Sendable, ConversationStreamingClient {
    typealias Model = FakeModel

    private let responses: [String]
    private var index = 0
    private(set) var lastRequest: AgentRequest?
    private(set) var lastModel: FakeModel?

    init(responses: [String]) {
        self.responses = responses
    }

    func stream(_ request: AgentRequest, model: FakeModel) -> AsyncThrowingStream<String, Error> {
        lastRequest = request
        lastModel = model
        let response = index < responses.count ? responses[index] : ""
        index += 1

        return AsyncThrowingStream { continuation in
            Task {
                continuation.yield(response)
                continuation.finish()
            }
        }
    }
}
