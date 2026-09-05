import Foundation
import Structure

public actor InMemoryMemoryStore: MemoryStore {
    private var recordsByID: [UUID: MemoryRecord] = [:]
    private var recordOrder: [UUID] = []

    public init() {}

    public func upsert(_ record: MemoryRecord) async throws {
        if recordsByID[record.id] == nil {
            recordOrder.append(record.id)
        }
        recordsByID[record.id] = record
    }

    public func record(id: UUID) async throws -> MemoryRecord? {
        recordsByID[id]
    }

    public func records(sessionKey: MemorySessionKey, includeArchived: Bool = false) async throws -> [MemoryRecord] {
        recordOrder.compactMap { recordsByID[$0] }.filter {
            $0.pair.sessionID == sessionKey.sessionID
                && $0.pair.agentID == sessionKey.agentID
                && MemoryQueryPolicy.isWithinRetention($0.pair.createdAt, includeArchived: includeArchived)
        }
    }

    public func search(
        sessionKey: MemorySessionKey,
        query: String,
        limit: Int,
        includeArchived: Bool = false
    ) async throws -> [MemoryRecord] {
        let pageSize = MemoryQueryPolicy.clampedRowLimit(limit)
        let tokens = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let ranked = try await records(sessionKey: sessionKey, includeArchived: includeArchived).map { record in
            (record, Self.score(record: record, tokens: tokens))
        }

        return ranked
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.pair.createdAt < rhs.0.pair.createdAt
                }
                return lhs.1 > rhs.1
            }
            .prefix(pageSize)
            .map(\.0)
    }

    public func searchPrior(
        sessionKey: MemorySessionKey,
        query: String?,
        limit: Int,
        page: Int,
        includeArchived: Bool = false
    ) async throws -> [MemoryRecord] {
        let filtered = recordOrder.compactMap { recordsByID[$0] }.filter {
            ($0.pair.sessionID != sessionKey.sessionID || $0.pair.agentID != sessionKey.agentID)
                && MemoryQueryPolicy.isWithinRetention($0.pair.createdAt, includeArchived: includeArchived)
        }

        let matching: [MemoryRecord]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tokens = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
            matching = filtered.filter { record in
                Self.score(record: record, tokens: tokens) > 0
            }
        } else {
            matching = filtered
        }

        let pageSize = MemoryQueryPolicy.clampedRowLimit(limit)
        let pageIndex = max(page, 1)
        let start = (pageIndex - 1) * pageSize
        guard start < matching.count else {
            return []
        }

        return Array(matching.sorted { $0.pair.createdAt > $1.pair.createdAt }.dropFirst(start).prefix(pageSize))
    }

    private static func score(record: MemoryRecord, tokens: [String]) -> Int {
        let rawText = [record.pair.prompt, record.pair.completion].joined(separator: " ").lowercased()
        let detailedText = record.detailedSummary?.text.lowercased() ?? ""
        let compressedText = record.compressedSummary?.text.lowercased() ?? ""
        let keywords = Set((record.detailedSummary?.metadata.keywords ?? []) + (record.compressedSummary?.metadata.keywords ?? []))

        return tokens.reduce(into: 0) { score, token in
            if keywords.contains(token) {
                score += 5
            }
            if rawText.contains(token) {
                score += 2
            }
            if detailedText.contains(token) {
                score += 3
            }
            if compressedText.contains(token) {
                score += 4
            }
        }
    }
}
