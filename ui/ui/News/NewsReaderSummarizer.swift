import Foundation
import LLMAgentClient
import Structure

struct NewsReaderSummarizer: NewsSummaryGenerating {
    let settings: LLMModelSettings

    func summarize(listName: String, topics: [String], articles: [NewsItem]) async throws -> String {
        let model = await MainActor.run { settings.summarizerModel }
        guard let apiKey = await LLMProviderCredentialGate.resolveAPIKey(for: model) else {
            throw NewsReaderError.summarizerUnavailable
        }

        let prompt = Self.prompt(listName: listName, topics: topics, articles: articles)
        let request = AgentRequest.prompt(
            prompt,
            system: """
            You summarize news for the user. Write clear prose in plain English.
            Use bullet points. Include markdown links to the original articles using the URLs provided.
            Do not add a title or markdown heading for the list name.
            Cover every article provided when possible.
            Do not invent stories or URLs.
            """,
            temperature: 0.2
        )
        let text: String
        switch model {
        case .gemini(let geminiModel):
            let client = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
            text = try await collect(client.stream(request, model: geminiModel))
        case .openai(let openAIModel):
            let client = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
            text = try await collect(client.stream(request, model: openAIModel))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NewsReaderError.fetchFailed(url: listName, detail: "Summarizer returned an empty response.")
        }
        return trimmed
    }

    private func collect(_ stream: AsyncThrowingStream<AgentStreamEvent, Error>) async throws -> String {
        let (text, usage) = try await collectAgentStream(stream)
        if let usage {
            _ = await UsageLimitsService.shared.recordAPIUsage(usage)
        }
        return text
    }

    private static func prompt(listName: String, topics: [String], articles: [NewsItem]) -> String {
        var lines = [
            "Summarize these articles for the list \"\(listName)\".",
        ]
        if !topics.isEmpty {
            lines.append("Topics: \(topics.joined(separator: ", "))")
        }
        lines.append("Articles:")
        for article in articles.prefix(12) {
            var entry = "- \(article.title) (\(article.sourceURL))"
            if let detail = article.summary, !detail.isEmpty {
                entry += "\n  \(detail)"
            }
            lines.append(entry)
        }
        return lines.joined(separator: "\n")
    }
}
