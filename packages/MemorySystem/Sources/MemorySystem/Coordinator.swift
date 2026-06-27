import Foundation

public struct MemoryIngestInput: Hashable, Codable, Sendable {
    public let sessionKey: MemorySessionKey
    public let parentAgentID: String?
    public let prompt: String
    public let completion: String
    public let toolCalls: [ToolCallRecord]
    public let scope: MemoryAccessibility

    public init(
        sessionKey: MemorySessionKey,
        parentAgentID: String? = nil,
        prompt: String,
        completion: String,
        toolCalls: [ToolCallRecord] = [],
        scope: MemoryAccessibility = .private
    ) {
        self.sessionKey = sessionKey
        self.parentAgentID = parentAgentID
        self.prompt = prompt
        self.completion = completion
        self.toolCalls = toolCalls
        self.scope = scope
    }
}

public actor MemoryCoordinator {
    private let store: any MemoryStore
    private let summarizer: any MemorySummarizer
    private let policy: any MemoryCompactionPolicy
    private let budget: MemoryBudget
    private var workingSets: [MemorySessionKey: [MemoryWorkingEntry]] = [:]

    public init(
        store: any MemoryStore,
        summarizer: any MemorySummarizer = DefaultMemorySummarizer(),
        policy: any MemoryCompactionPolicy = TieredMemoryCompactionPolicy(),
        budget: MemoryBudget
    ) {
        self.store = store
        self.summarizer = summarizer
        self.policy = policy
        self.budget = budget
    }

    public func ingest(_ input: MemoryIngestInput) async throws {
        let pair = PromptResponsePair(
            sessionID: input.sessionKey.sessionID,
            agentID: input.sessionKey.agentID,
            parentAgentID: input.parentAgentID,
            prompt: input.prompt,
            completion: input.completion,
            toolCalls: input.toolCalls
        )

        let record = MemoryRecord(pair: pair, scope: input.scope)
        try await store.upsert(record)

        let entry = MemoryWorkingEntry(
            sessionKey: input.sessionKey,
            parentAgentID: input.parentAgentID,
            createdAt: pair.createdAt,
            rawPair: pair,
            scope: input.scope
        )

        workingSets[input.sessionKey, default: []].append(entry)
        try await compact(sessionKey: input.sessionKey)
    }

    public func records(for sessionKey: MemorySessionKey) async -> [MemoryWorkingEntry] {
        workingSets[sessionKey, default: []]
    }

    public func retrieve(_ request: MemoryRetrievalRequest) async throws -> MemoryRetrievalResult {
        let local = workingSets[request.sessionKey, default: []]
        let persisted = try await store.records(sessionKey: request.sessionKey)
            .map { record in
                MemoryWorkingEntry(
                    id: record.id,
                    sessionKey: request.sessionKey,
                    parentAgentID: record.pair.parentAgentID,
                    createdAt: record.pair.createdAt,
                    rawPair: record.pair,
                    detailedSummary: record.detailedSummary,
                    compressedSummary: record.compressedSummary,
                    scope: record.scope
                )
            }

        let combined = merge(entries: local + persisted)
        let ranked = rank(entries: combined, query: request.query)
        let selected = Array(ranked.prefix(request.limit))
        let context = renderContext(for: selected)
        let tokenCount = selected.reduce(0) { $0 + $1.estimatedTokenCount }
        return MemoryRetrievalResult(entries: selected, context: context, estimatedTokenCount: tokenCount)
    }

    public func compact(sessionKey: MemorySessionKey) async throws {
        var entries = workingSets[sessionKey, default: []]
        let plan = policy.plan(entries: entries, budget: budget)

        for instruction in plan.instructions {
            switch instruction {
            case .summarize(let id):
                try await summarize(entryID: id, in: &entries)
            case .dropRaw(let id):
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].rawPair = nil
                }
            case .dropDetailed(let id):
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].detailedSummary = nil
                }
            case .dropCompressed(let id):
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].compressedSummary = nil
                }
            }
        }

        workingSets[sessionKey] = entries
    }

    private func summarize(entryID: UUID, in entries: inout [MemoryWorkingEntry]) async throws {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              let raw = entries[index].rawPair else {
            return
        }

        let summaries = try await summarizer.summarize(raw)
        entries[index].detailedSummary = summaries.layer2
        entries[index].compressedSummary = summaries.layer1

        try await store.upsert(
            MemoryRecord(
                id: raw.id,
                pair: raw,
                scope: entries[index].scope,
                compressedSummary: summaries.layer1,
                detailedSummary: summaries.layer2
            )
        )
    }

    private func merge(entries: [MemoryWorkingEntry]) -> [MemoryWorkingEntry] {
        var byID: [UUID: MemoryWorkingEntry] = [:]
        for entry in entries.reversed() {
            byID[entry.id] = entry
        }
        return byID.values.sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func rank(entries: [MemoryWorkingEntry], query: String?) -> [MemoryWorkingEntry] {
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return entries.sorted { $0.createdAt > $1.createdAt }
        }

        let tokens = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return entries
            .map { entry in
                (entry, score(entry: entry, tokens: tokens))
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.createdAt > rhs.0.createdAt
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
    }

    private func score(entry: MemoryWorkingEntry, tokens: [String]) -> Int {
        let raw = [entry.rawPair?.prompt ?? "", entry.rawPair?.completion ?? ""].joined(separator: " ").lowercased()
        let detailed = entry.detailedSummary?.text.lowercased() ?? ""
        let compressed = entry.compressedSummary?.text.lowercased() ?? ""
        let keywords = Set((entry.detailedSummary?.metadata.keywords ?? []) + (entry.compressedSummary?.metadata.keywords ?? []))

        return tokens.reduce(into: 0) { score, token in
            if keywords.contains(token) {
                score += 5
            }
            if compressed.contains(token) {
                score += 4
            }
            if detailed.contains(token) {
                score += 3
            }
            if raw.contains(token) {
                score += 2
            }
        }
    }

    private func renderContext(for entries: [MemoryWorkingEntry]) -> String {
        entries.map { entry in
            if let summary = entry.compressedSummary {
                return summary.text
            }
            if let summary = entry.detailedSummary {
                return summary.text
            }
            if let raw = entry.rawPair {
                return "Prompt: \(raw.prompt)\nCompletion: \(raw.completion)"
            }
            return ""
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }
}
