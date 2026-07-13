import Combine
import Foundation
import LLMAgentClient
import MCPServer

private enum HelperModelSettingsKey {
    static let summarizerModel = "helperModelSettings.summarizerModel"
    static let pythonScriptReviewerModel = "helperModelSettings.pythonScriptReviewerModel"
}

@MainActor
final class HelperModelSettings: ObservableObject {
    @Published var summarizerModel: LLMModelChoice {
        didSet {
            persist(summarizerModel, forKey: HelperModelSettingsKey.summarizerModel)
        }
    }

    @Published var pythonScriptReviewerModel: LLMModelChoice {
        didSet {
            persist(pythonScriptReviewerModel, forKey: HelperModelSettingsKey.pythonScriptReviewerModel)
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        summarizerModel = Self.loadModel(
            forKey: HelperModelSettingsKey.summarizerModel,
            userDefaults: userDefaults
        )
        pythonScriptReviewerModel = Self.loadModel(
            forKey: HelperModelSettingsKey.pythonScriptReviewerModel,
            userDefaults: userDefaults
        )
    }

    private static func loadModel(forKey key: String, userDefaults: UserDefaults) -> LLMModelChoice {
        guard
            let data = userDefaults.data(forKey: key),
            let model = try? JSONDecoder().decode(LLMModelChoice.self, from: data)
        else {
            return .defaultHelperModel
        }
        return model
    }

    private func persist(_ model: LLMModelChoice, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(model)
            userDefaults.set(data, forKey: key)
        } catch {
            debugLog("Failed to persist helper model selection for \(key): \(error.localizedDescription)")
        }
    }
}

actor ConfiguredMemorySummarizer: MemorySummarizer {
    private struct Payload: Decodable {
        let layer1Text: String
        let layer2Text: String
        let keywords: [String]
    }

    private let settings: HelperModelSettings
    private let fallback: any MemorySummarizer
    private let systemPrompt: String
    private let keywordFilter = MemoryKeywordFilter()

    init(
        settings: HelperModelSettings,
        systemPrompt: String,
        fallback: any MemorySummarizer = DefaultMemorySummarizer()
    ) {
        self.settings = settings
        self.fallback = fallback
        self.systemPrompt = systemPrompt
    }

    func summarize(_ pair: PromptResponsePair) async throws -> MemorySummaryPair {
        let selectedModel = await MainActor.run { settings.summarizerModel }
        guard let apiKey = await resolveAPIKey(for: selectedModel) else {
            await MainActor.run {
                debugLog(
                    "Helper summarizer model \(selectedModel.helperDisplayName) unavailable; using fallback summarizer."
                )
            }
            return try await fallback.summarize(pair)
        }

        do {
            return try await summarize(pair, model: selectedModel, apiKey: apiKey)
        } catch {
            await MainActor.run {
                debugLog(
                    "Helper summarizer model \(selectedModel.helperDisplayName) failed: \(error.localizedDescription)"
                )
            }
            return try await fallback.summarize(pair)
        }
    }

    private func summarize(
        _ pair: PromptResponsePair,
        model: LLMModelChoice,
        apiKey: String
    ) async throws -> MemorySummaryPair {
        let request = AgentRequest.prompt(
            Self.userPrompt(for: pair),
            system: systemPrompt,
            temperature: 0
        )

        let response = try await streamResponse(for: request, model: model, apiKey: apiKey)
        let payload = try Self.parsePayload(from: response)
        let keywords = keywordFilter.filter(payload.keywords)

        let detailedSummary = Self.makeSummary(
            text: payload.layer2Text,
            keywords: keywords,
            sourceTokenCount: pair.totalTokenCount
        )
        let compressedSummary = Self.makeSummary(
            text: payload.layer1Text,
            keywords: keywords,
            sourceTokenCount: pair.totalTokenCount
        )

        return MemorySummaryPair(layer1: compressedSummary, layer2: detailedSummary)
    }

    private func streamResponse(
        for request: AgentRequest,
        model: LLMModelChoice,
        apiKey: String
    ) async throws -> String {
        switch model {
        case .gemini(let geminiModel):
            let client = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
            return try await collect(client.stream(request, model: geminiModel))
        case .openai(let openAIModel):
            let client = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
            return try await collect(client.stream(request, model: openAIModel))
        }
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var response = ""
        for try await chunk in stream {
            response += chunk
        }
        return response
    }

    private func resolveAPIKey(for model: LLMModelChoice) async -> String? {
        await MainActor.run {
            AppSecretResolver().resolve(
                account: model.provider.secretAccount,
                environmentKeys: model.provider.apiKeyEnvironmentKeys
            )
        }
    }

    private static func makeSummary(text: String, keywords: [String], sourceTokenCount: Int) -> MemorySummary {
        let summaryTokenCount = max(text.split(whereSeparator: \.isWhitespace).count, 1)
        let compressionRatio = Double(summaryTokenCount) / Double(max(sourceTokenCount, 1))
        return MemorySummary(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            metadata: MemorySummaryMetadata(
                keywords: keywords,
                compressionRatio: compressionRatio,
                sourceTokenCount: sourceTokenCount,
                summaryTokenCount: summaryTokenCount
            )
        )
    }

    private static func userPrompt(for pair: PromptResponsePair) -> String {
        var lines: [String] = []
        lines.append("Session: \(pair.sessionID)")
        lines.append("Agent: \(pair.agentID)")
        if let parentAgentID = pair.parentAgentID {
            lines.append("Parent agent: \(parentAgentID)")
        }
        lines.append("Prompt:")
        lines.append(pair.prompt)
        lines.append("Completion:")
        lines.append(pair.completion)

        if !pair.toolCalls.isEmpty {
            lines.append("Tool calls:")
            for toolCall in pair.toolCalls {
                let arguments = toolCall.arguments
                    .map { "\($0.key)=\($0.value)" }
                    .sorted()
                    .joined(separator: ", ")
                let result = toolCall.result ?? ""
                lines.append("- \(toolCall.name) [\(arguments)] -> \(result)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func parsePayload(from response: String) throws -> Payload {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String

        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw AgentError.responseDecodingFailed("Summarizer output was not UTF-8.")
        }

        do {
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw AgentError.responseDecodingFailed(String(describing: error))
        }
    }
}

actor ConfiguredPythonScriptReviewer: PythonScriptReviewer {
    nonisolated let name: String = "configured-python-script-reviewer"

    private let settings: HelperModelSettings

    init(settings: HelperModelSettings) {
        self.settings = settings
    }

    func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewAssessment {
        let selectedModel = await MainActor.run { settings.pythonScriptReviewerModel }
        guard let apiKey = await resolveAPIKey(for: selectedModel) else {
            await MainActor.run {
                debugLog(
                    "Helper reviewer model \(selectedModel.helperDisplayName) unavailable; using default Gemini reviewer."
                )
            }

            if let defaultReview = await defaultReviewerAssessment(for: args) {
                return defaultReview
            }

            throw NSError(
                domain: "ui",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No API key available for helper reviewer."]
            )
        }

        do {
            return try await review(args, model: selectedModel, apiKey: apiKey)
        } catch {
            await MainActor.run {
                debugLog(
                    "Helper reviewer model \(selectedModel.helperDisplayName) failed: \(error.localizedDescription)"
                )
            }
            if let defaultReview = await defaultReviewerAssessment(for: args) {
                return defaultReview
            }
            throw error
        }
    }

    private func defaultReviewerAssessment(for args: PythonScriptExecutionArguments) async -> PythonScriptReviewAssessment? {
        guard let apiKey = await resolveAPIKey(for: .defaultHelperModel) else {
            return nil
        }

        do {
            return try await review(args, model: .defaultHelperModel, apiKey: apiKey)
        } catch {
            await MainActor.run {
                debugLog("Default helper reviewer failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func review(
        _ args: PythonScriptExecutionArguments,
        model: LLMModelChoice,
        apiKey: String
    ) async throws -> PythonScriptReviewAssessment {
        switch model {
        case .gemini(let geminiModel):
            let reviewer = GeminiPythonScriptReviewer(apiKey: apiKey, model: geminiModel)
            return try await reviewer.review(args)
        case .openai(let openAIModel):
            let reviewer = OpenAIPythonScriptReviewer(apiKey: apiKey, model: openAIModel)
            return try await reviewer.review(args)
        }
    }

    private func resolveAPIKey(for model: LLMModelChoice) async -> String? {
        await MainActor.run {
            AppSecretResolver().resolve(
                account: model.provider.secretAccount,
                environmentKeys: model.provider.apiKeyEnvironmentKeys
            )
        }
    }
}
