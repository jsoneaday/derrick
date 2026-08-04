import Foundation
import LLMAgentClient
import MCPServer
import MemorySystem

/// Python security reviewer for MCPService using the turn-supplied API key.
struct MCPServicePythonReviewer: PythonScriptReviewer {
    nonisolated let name: String = "mcp-service-python-reviewer"

    func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewOutcome {
        guard let apiKey = MCPServiceCallContext.shared.helperAPIKey,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw NSError(
                domain: "MCPService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No API key available for python security reviewer."]
            )
        }

        // Prefer OpenAI helper model; fall back to Gemini if OpenAI review fails hard.
        do {
            let openai = OpenAIPythonScriptReviewer(apiKey: apiKey, model: .gpt56Luna)
            return try await openai.review(args)
        } catch {
            fputs(
                "[MCPService] OpenAI reviewer failed: \(error.localizedDescription); trying Gemini\n",
                stderr
            )
            let gemini = GeminiPythonScriptReviewer(apiKey: apiKey, model: .gemini25FlashLite)
            return try await gemini.review(args)
        }
    }
}

/// Process-wide slots for the current MCPService tool call (handlers may not inherit TaskLocal).
final class MCPServiceCallContext: @unchecked Sendable {
    static let shared = MCPServiceCallContext()

    private let lock = NSLock()
    private var _helperAPIKey: String?
    private var _memorySessionKey: MemorySessionKey?

    private init() {}

    func install(helperAPIKey: String?, memorySessionKey: MemorySessionKey) {
        lock.lock()
        _helperAPIKey = helperAPIKey
        _memorySessionKey = memorySessionKey
        lock.unlock()
    }

    func clear() {
        lock.lock()
        _helperAPIKey = nil
        _memorySessionKey = nil
        lock.unlock()
    }

    var helperAPIKey: String? {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = _helperAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var memorySessionKey: MemorySessionKey? {
        lock.lock()
        defer { lock.unlock() }
        return _memorySessionKey
    }
}
