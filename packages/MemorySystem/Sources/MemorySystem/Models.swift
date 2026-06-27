import Foundation

public struct MemorySessionKey: Hashable, Codable, Sendable {
    public let sessionID: String
    public let agentID: String

    public init(sessionID: String, agentID: String) {
        self.sessionID = sessionID
        self.agentID = agentID
    }
}

public enum MemoryScope: String, Codable, Sendable {
    case `private`
    case shared
    case broadcast
}

public enum MemoryLayer: Int, Codable, CaseIterable, Sendable {
    case compressed = 1
    case detailed = 2
    case raw = 3
}

public struct ToolCallRecord: Hashable, Codable, Sendable {
    public let name: String
    public let arguments: [String: String]
    public let result: String?
    public let occurredAt: Date

    public init(name: String, arguments: [String: String] = [:], result: String? = nil, occurredAt: Date = .now) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.occurredAt = occurredAt
    }
}

public struct PromptResponsePair: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let sessionID: String
    public let agentID: String
    public let parentAgentID: String?
    public let prompt: String
    public let completion: String
    public let toolCalls: [ToolCallRecord]
    public let createdAt: Date
    public let promptTokenCount: Int
    public let completionTokenCount: Int

    public init(
        id: UUID = UUID(),
        sessionID: String,
        agentID: String,
        parentAgentID: String? = nil,
        prompt: String,
        completion: String,
        toolCalls: [ToolCallRecord] = [],
        createdAt: Date = .now,
        promptTokenCount: Int? = nil,
        completionTokenCount: Int? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agentID = agentID
        self.parentAgentID = parentAgentID
        self.prompt = prompt
        self.completion = completion
        self.toolCalls = toolCalls
        self.createdAt = createdAt
        self.promptTokenCount = promptTokenCount ?? Self.approximateTokenCount(for: prompt)
        self.completionTokenCount = completionTokenCount ?? Self.approximateTokenCount(for: completion)
    }

    public var totalTokenCount: Int {
        promptTokenCount + completionTokenCount
    }

    private static func approximateTokenCount(for text: String) -> Int {
        let words = text.split(whereSeparator: \.isWhitespace)
        return max(words.count, 1)
    }
}

public struct MemorySummaryMetadata: Hashable, Codable, Sendable {
    public let keywords: [String]
    public let semanticSimilarity: Double?
    public let compressionRatio: Double
    public let sourceTokenCount: Int
    public let summaryTokenCount: Int

    public init(
        keywords: [String],
        semanticSimilarity: Double? = nil,
        compressionRatio: Double,
        sourceTokenCount: Int,
        summaryTokenCount: Int
    ) {
        self.keywords = keywords
        self.semanticSimilarity = semanticSimilarity
        self.compressionRatio = compressionRatio
        self.sourceTokenCount = sourceTokenCount
        self.summaryTokenCount = summaryTokenCount
    }
}

public struct MemorySummary: Hashable, Codable, Sendable {
    public let text: String
    public let metadata: MemorySummaryMetadata

    public init(text: String, metadata: MemorySummaryMetadata) {
        self.text = text
        self.metadata = metadata
    }
}

public struct MemoryRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let pair: PromptResponsePair
    public let scope: MemoryScope
    public var compressedSummary: MemorySummary?
    public var detailedSummary: MemorySummary?

    public init(
        id: UUID = UUID(),
        pair: PromptResponsePair,
        scope: MemoryScope = .private,
        compressedSummary: MemorySummary? = nil,
        detailedSummary: MemorySummary? = nil
    ) {
        self.id = id
        self.pair = pair
        self.scope = scope
        self.compressedSummary = compressedSummary
        self.detailedSummary = detailedSummary
    }
}

public struct MemoryWorkingEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let sessionKey: MemorySessionKey
    public let parentAgentID: String?
    public let createdAt: Date
    public var rawPair: PromptResponsePair?
    public var detailedSummary: MemorySummary?
    public var compressedSummary: MemorySummary?
    public let scope: MemoryScope

    public init(
        id: UUID = UUID(),
        sessionKey: MemorySessionKey,
        parentAgentID: String? = nil,
        createdAt: Date,
        rawPair: PromptResponsePair? = nil,
        detailedSummary: MemorySummary? = nil,
        compressedSummary: MemorySummary? = nil,
        scope: MemoryScope = .private
    ) {
        self.id = id
        self.sessionKey = sessionKey
        self.parentAgentID = parentAgentID
        self.createdAt = createdAt
        self.rawPair = rawPair
        self.detailedSummary = detailedSummary
        self.compressedSummary = compressedSummary
        self.scope = scope
    }

    public var estimatedTokenCount: Int {
        if let rawPair {
            return rawPair.totalTokenCount
        }

        let detailedTokens = detailedSummary?.metadata.summaryTokenCount ?? 0
        let compressedTokens = compressedSummary?.metadata.summaryTokenCount ?? 0
        return max(detailedTokens, compressedTokens)
    }
}

public struct MemoryBudget: Hashable, Codable, Sendable {
    public let maxTokenCount: Int

    public init(maxTokenCount: Int) {
        self.maxTokenCount = maxTokenCount
    }
}

public struct MemoryRetrievalRequest: Hashable, Codable, Sendable {
    public let sessionKey: MemorySessionKey
    public let query: String?
    public let limit: Int
    public let includeShared: Bool
    public let includeParentLineage: Bool

    public init(
        sessionKey: MemorySessionKey,
        query: String? = nil,
        limit: Int = 10,
        includeShared: Bool = true,
        includeParentLineage: Bool = true
    ) {
        self.sessionKey = sessionKey
        self.query = query
        self.limit = limit
        self.includeShared = includeShared
        self.includeParentLineage = includeParentLineage
    }
}

public struct MemoryRetrievalResult: Hashable, Codable, Sendable {
    public let entries: [MemoryWorkingEntry]
    public let context: String
    public let estimatedTokenCount: Int

    public init(entries: [MemoryWorkingEntry], context: String, estimatedTokenCount: Int) {
        self.entries = entries
        self.context = context
        self.estimatedTokenCount = estimatedTokenCount
    }
}
