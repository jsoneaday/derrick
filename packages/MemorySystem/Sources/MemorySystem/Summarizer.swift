import Foundation

public struct MemorySummaryPair: Hashable, Codable, Sendable {
    public let layer1: MemorySummary
    public let layer2: MemorySummary

    public init(layer1: MemorySummary, layer2: MemorySummary) {
        self.layer1 = layer1
        self.layer2 = layer2
    }
}

public protocol MemorySummarizer: Sendable {
    func summarize(_ pair: PromptResponsePair) async throws -> MemorySummaryPair
}

public struct MemoryKeywordFilter: Sendable {
    public init() {}

    public func filter(_ keywords: [String]) -> [String] {
        let blocked = Set([
            "tool",
            "tools",
            "mcp",
            "client",
            "server",
            "openai",
            "gemini",
            "gpt",
            "model"
        ])

        var seen = Set<String>()
        return keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !blocked.contains($0) && seen.insert($0).inserted }
    }
}

public struct MemorySummaryComposer: Sendable {
    private let keywordFilter: MemoryKeywordFilter

    public init(keywordFilter: MemoryKeywordFilter = MemoryKeywordFilter()) {
        self.keywordFilter = keywordFilter
    }

    public func makeLayer2Summary(from pair: PromptResponsePair, toolContext: [ToolCallRecord]) -> String {
        var parts: [String] = []
        parts.append("Prompt: \(pair.prompt)")
        parts.append("Completion: \(pair.completion)")

        if !toolContext.isEmpty {
            let tools = toolContext.map { call in
                "\(call.name): \(call.result ?? "")"
            }.joined(separator: " | ")
            parts.append("Tools: \(tools)")
        }

        return parts.joined(separator: "\n")
    }

    public func makeLayer1Summary(from pair: PromptResponsePair, detailedSummary: String, keywords: [String]) -> String {
        let keywordText = keywords.isEmpty ? "none" : keywords.joined(separator: ", ")
        return [
            "Intent: \(pair.prompt)",
            "Outcome: \(pair.completion)",
            "Keywords: \(keywordText)",
            "Digest: \(detailedSummary)"
        ].joined(separator: "\n")
    }

    public func makeKeywords(from pair: PromptResponsePair, detailedSummary: String) -> [String] {
        let promptTokens = extractSemanticTokens(from: pair.prompt)
        let completionTokens = extractSemanticTokens(from: pair.completion)
        let summaryTokens = extractSemanticTokens(from: detailedSummary)
        return keywordFilter.filter(promptTokens + completionTokens + summaryTokens)
    }

    private func extractSemanticTokens(from text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        let words = text
            .lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let stopWords: Set<String> = [
            "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with", "is", "are",
            "was", "were", "be", "been", "that", "this", "it", "as", "at", "by", "from", "we",
            "you", "i", "they", "them", "our", "your", "their", "will", "should", "can", "could",
            "need", "make", "use", "using", "about", "into", "when", "what", "how", "why"
        ]

        return words.filter { !stopWords.contains($0) }
    }
}

public struct DefaultMemorySummarizer: MemorySummarizer {
    private let composer: MemorySummaryComposer

    public init(composer: MemorySummaryComposer = MemorySummaryComposer()) {
        self.composer = composer
    }

    public func summarize(_ pair: PromptResponsePair) async throws -> MemorySummaryPair {
        let detailedText = composer.makeLayer2Summary(from: pair, toolContext: pair.toolCalls)
        let keywords = composer.makeKeywords(from: pair, detailedSummary: detailedText)
        let compressedText = composer.makeLayer1Summary(from: pair, detailedSummary: detailedText, keywords: keywords)

        let detailedSummary = MemorySummary(
            text: detailedText,
            metadata: MemorySummaryMetadata(
                keywords: keywords,
                compressionRatio: compressionRatio(source: pair, summary: detailedText),
                sourceTokenCount: pair.totalTokenCount,
                summaryTokenCount: approximateTokenCount(detailedText)
            )
        )

        let compressedSummary = MemorySummary(
            text: compressedText,
            metadata: MemorySummaryMetadata(
                keywords: keywords,
                compressionRatio: compressionRatio(source: pair, summary: compressedText),
                sourceTokenCount: pair.totalTokenCount,
                summaryTokenCount: approximateTokenCount(compressedText)
            )
        )

        return MemorySummaryPair(layer1: compressedSummary, layer2: detailedSummary)
    }

    private func compressionRatio(source: PromptResponsePair, summary: String) -> Double {
        let sourceTokens = max(source.totalTokenCount, 1)
        let summaryTokens = max(approximateTokenCount(summary), 1)
        return Double(summaryTokens) / Double(sourceTokens)
    }

    private func approximateTokenCount(_ text: String) -> Int {
        max(text.split(whereSeparator: \.isWhitespace).count, 1)
    }
}
