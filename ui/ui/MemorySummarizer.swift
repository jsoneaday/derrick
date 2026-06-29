import Foundation
import LLMAgentClient

actor GeminiMemorySummarizer: MemorySummarizer {
    private struct Payload: Decodable {
        let layer1Text: String
        let layer2Text: String
        let keywords: [String]
    }

    private let model: GeminiModel
    private let fallback: any MemorySummarizer
    private let systemPrompt: String
    private let keywordFilter = MemoryKeywordFilter()

    init(
        model: GeminiModel = .gemini25FlashLite,
        systemPrompt: String,
        fallback: any MemorySummarizer = DefaultMemorySummarizer()
    ) {
        self.model = model
        self.fallback = fallback
        self.systemPrompt = systemPrompt
    }

    func summarize(_ pair: PromptResponsePair) async throws -> MemorySummaryPair {
        let apiKey = await MainActor.run {
            AppSecretResolver().resolve(
                account: "gemini-api-key",
                environmentKeys: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            )
        }

        guard let apiKey else {
            return try await fallback.summarize(pair)
        }

        do {
            return try await summarizeWithGemini(pair, apiKey: apiKey)
        } catch {
            return try await fallback.summarize(pair)
        }
    }

    private func summarizeWithGemini(_ pair: PromptResponsePair, apiKey: String) async throws -> MemorySummaryPair {
        let client = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
        let request = AgentRequest.prompt(
            Self.userPrompt(for: pair),
            system: systemPrompt,
            temperature: 0
        )

        let stream = client.stream(request, model: model)
        var response = ""
        for try await chunk in stream {
            response += chunk
        }

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
