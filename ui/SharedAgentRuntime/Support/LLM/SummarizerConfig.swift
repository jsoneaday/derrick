//
//  SummarizerInit.swift
//  ui
//
//  Created by David Choi on 7/21/26.
//

import Foundation
import MemorySystem
import LLMAgentClient

actor ConfiguredMemorySummarizer: MemorySummarizer {
    private struct Payload: Decodable {
        let layer1Text: String
        let layer2Text: String
        let keywords: [String]
    }

    private let settings: LLMModelSettings
    private let fallback: any MemorySummarizer
    private let systemPrompt: String
    private let keywordFilter = MemoryKeywordFilter()

    init(
        settings: LLMModelSettings,
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
                LLMFailureReporter.shared.report(
                    LLMFailureClassifier.classify(error, provider: selectedModel.provider)
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

    private func collect(_ stream: AsyncThrowingStream<AgentStreamEvent, Error>) async throws -> String {
        let (text, usage) = try await collectAgentStream(stream)
        if let usage {
            _ = await UsageLimitsService.shared.recordAPIUsage(usage)
        }
        return text
    }

    private func resolveAPIKey(for model: LLMModelChoice) async -> String? {
        if let key = await MainActor.run(body: {
            AppSecretResolver().resolve(
                account: model.provider.secretAccount,
                environmentKeys: model.provider.apiKeyEnvironmentKeys
            )
        }), !key.isEmpty {
            return key
        }
        return TurnProcessContext.effectiveAPIKey
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
