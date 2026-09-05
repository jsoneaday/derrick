import Foundation

public protocol MemoryStore: Sendable {
    func upsert(_ record: MemoryRecord) async throws
    func record(id: UUID) async throws -> MemoryRecord?
    func records(sessionKey: MemorySessionKey, includeArchived: Bool) async throws -> [MemoryRecord]
    func search(sessionKey: MemorySessionKey, query: String, limit: Int, includeArchived: Bool) async throws -> [MemoryRecord]
    func searchPrior(
        sessionKey: MemorySessionKey,
        query: String?,
        limit: Int,
        page: Int,
        includeArchived: Bool
    ) async throws -> [MemoryRecord]
}
