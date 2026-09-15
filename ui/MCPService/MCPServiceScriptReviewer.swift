import Foundation
import LLMAgentClient
import MCPServer
import MemorySystem
import Structure

/// Script security reviewer for MCPService using turn-supplied API key + model settings.
/// Model selection comes from UI `LLMModelSettings.scriptReviewerModel` via
/// `HelperModelWire` on each `callTool` request.
struct MCPServiceScriptReviewer: ScriptReviewer {
    nonisolated let name: String
    let systemPrompt: String

    init(
        name: String = "mcp-service-script-reviewer",
        systemPrompt: String = ReviewerSystemPrompt
    ) {
        self.name = name
        self.systemPrompt = systemPrompt
    }

    func review(_ args: ScriptExecutionArguments) async throws -> ScriptReviewOutcome {
        let selected = resolveSelectedModel()
        guard let apiKey = await resolveAPIKey(for: selected) else {
            throw NSError(
                domain: "MCPService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No API key available for script security reviewer."]
            )
        }

        do {
            return try await review(args, model: selected, apiKey: apiKey)
        } catch {
            fputs(
                "[MCPService] reviewer model \(selected.label) failed: \(error.localizedDescription); trying defaults\n",
                stderr
            )
            if let fallback = await fallbackReview(args: args, excluding: selected) {
                return fallback
            }
            throw error
        }
    }

    // MARK: - Model selection

    private enum ReviewerModel: Equatable {
        case openai(OpenAIModel)
        case gemini(GeminiModel)

        var label: String {
            switch self {
            case .openai(let m): return "openai:\(m.rawValue)"
            case .gemini(let m): return "google:\(m.rawValue)"
            }
        }
    }

    private static let defaultModel: ReviewerModel = .openai(.gpt56Luna)
    private static let secondaryDefault: ReviewerModel = .gemini(.gemini25FlashLite)

    private func resolveSelectedModel() -> ReviewerModel {
        guard let json = MCPServiceCallContext.shared.helperReviewerModelJSON,
              let wire = try? HelperModelWire.decodeJSON(json),
              let model = Self.model(from: wire)
        else {
            return Self.defaultModel
        }
        return model
    }

    private static func model(from wire: HelperModelWire) -> ReviewerModel? {
        switch wire.provider {
        case "openai":
            guard let m = OpenAIModel(rawValue: wire.model) else { return nil }
            return .openai(m)
        case "google":
            guard let m = GeminiModel(rawValue: wire.model) else { return nil }
            return .gemini(m)
        default:
            return nil
        }
    }

    private func review(
        _ args: ScriptExecutionArguments,
        model: ReviewerModel,
        apiKey: String
    ) async throws -> ScriptReviewOutcome {
        switch model {
        case .openai(let openAIModel):
            return try await OpenAIScriptReviewer(
                apiKey: apiKey,
                model: openAIModel,
                systemPrompt: systemPrompt
            ).review(args)
        case .gemini(let geminiModel):
            return try await GeminiScriptReviewer(
                apiKey: apiKey,
                model: geminiModel,
                systemPrompt: systemPrompt
            ).review(args)
        }
    }

    private func fallbackReview(
        args: ScriptExecutionArguments,
        excluding: ReviewerModel
    ) async -> ScriptReviewOutcome? {
        var candidates: [ReviewerModel] = [Self.defaultModel, Self.secondaryDefault]
        candidates.removeAll { $0 == excluding }
        for candidate in candidates {
            guard let apiKey = await resolveAPIKey(for: candidate) else { continue }
            do {
                let outcome = try await review(args, model: candidate, apiKey: apiKey)
                fputs("[MCPService] fallback reviewer succeeded model=\(candidate.label)\n", stderr)
                return outcome
            } catch {
                fputs(
                    "[MCPService] fallback reviewer failed model=\(candidate.label): \(error.localizedDescription)\n",
                    stderr
                )
            }
        }
        return nil
    }

    private func resolveAPIKey(for model: ReviewerModel) async -> String? {
        await LLMProviderCredentialGate.resolveAPIKey(for: llmModelChoice(from: model))
    }

    private func llmModelChoice(from model: ReviewerModel) -> LLMModelChoice {
        switch model {
        case .openai(let openAIModel):
            return .openai(openAIModel)
        case .gemini(let geminiModel):
            return .gemini(geminiModel)
        }
    }
}

/// Process-wide slots for the current MCPService tool call (handlers may not inherit TaskLocal).
final class MCPServiceCallContext: @unchecked Sendable {
    static let shared = MCPServiceCallContext()

    private let lock = NSLock()
    private var _helperAPIKey: String?
    private var _helperReviewerModelJSON: String?
    private var _memorySessionKey: MemorySessionKey?
    private var _pluginFactoryCreationActive = false
    private var _workflowID: String?

    private init() {}

    func install(
        helperAPIKey: String?,
        helperReviewerModelJSON: String?,
        memorySessionKey: MemorySessionKey,
        pluginFactoryCreationActive: Bool = false,
        workflowID: String? = nil
    ) {
        lock.lock()
        _helperAPIKey = helperAPIKey
        _helperReviewerModelJSON = helperReviewerModelJSON
        _memorySessionKey = memorySessionKey
        _pluginFactoryCreationActive = pluginFactoryCreationActive
        _workflowID = workflowID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        lock.unlock()
    }

    func clear() {
        lock.lock()
        _helperAPIKey = nil
        _helperReviewerModelJSON = nil
        _memorySessionKey = nil
        _pluginFactoryCreationActive = false
        _workflowID = nil
        lock.unlock()
    }

    var helperAPIKey: String? {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = _helperAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var helperReviewerModelJSON: String? {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = _helperReviewerModelJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var memorySessionKey: MemorySessionKey? {
        lock.lock()
        defer { lock.unlock() }
        return _memorySessionKey
    }

    var pluginFactoryCreationActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _pluginFactoryCreationActive
    }

    var workflowID: String? {
        lock.lock()
        defer { lock.unlock() }
        return _workflowID
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
