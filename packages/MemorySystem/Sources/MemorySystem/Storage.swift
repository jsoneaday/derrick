import Foundation

public protocol MemoryStore: Sendable {
    func upsert(_ record: MemoryRecord) async throws
    func record(id: UUID) async throws -> MemoryRecord?
    func records(sessionKey: MemorySessionKey) async throws -> [MemoryRecord]
    func search(sessionKey: MemorySessionKey, query: String, limit: Int) async throws -> [MemoryRecord]
}

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

    public func records(sessionKey: MemorySessionKey) async throws -> [MemoryRecord] {
        recordOrder.compactMap { recordsByID[$0] }.filter {
            $0.pair.sessionID == sessionKey.sessionID && $0.pair.agentID == sessionKey.agentID
        }
    }

    public func search(sessionKey: MemorySessionKey, query: String, limit: Int) async throws -> [MemoryRecord] {
        let tokens = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let ranked = try await records(sessionKey: sessionKey).map { record in
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
            .prefix(limit)
            .map(\.0)
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
