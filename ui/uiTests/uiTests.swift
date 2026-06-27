import Foundation
import LLMAgentClient
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
