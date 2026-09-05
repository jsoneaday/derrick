import Foundation
import SQLite3
import MemorySystem
import Structure

public extension DBRepository {
    func migrateSessionMemory(username: String, password: String, to targetVersion: Int? = nil) throws -> URL {
        try authenticate(username: username, password: password)
        try Self.ensureDirectory(at: databaseDirectoryURL)

        let target = targetVersion ?? DatabaseSchema.latestVersion
        guard target >= 0, target <= DatabaseSchema.latestVersion else {
            throw DBRepositoryError.unsupportedMigrationVersion(target)
        }

        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let storedVersion = try? withDatabaseHandle { try Self.schemaVersion(on: $0) }
            if let storedVersion, storedVersion != 0, storedVersion != target {
                fputs(
                    "[DBRepository] dev reset: schema version \(storedVersion) != \(target); recreating database\n",
                    stderr
                )
                try Self.deleteDatabaseFiles(at: databaseURL)
            }
        }

        try withDatabaseHandle { handle in
            var currentVersion = try Self.schemaVersion(on: handle)

            if currentVersion < target {
                for version in (currentVersion + 1)...target {
                    try Self.applyMemoryMigration(version: version, isUp: true, on: handle)
                }
            } else if currentVersion > target {
                for version in stride(from: currentVersion, to: target, by: -1) {
                    try Self.applyMemoryMigration(version: version, isUp: false, on: handle)
                }
            }
        }
        return databaseURL
    }

    func currentMemorySchemaVersion(username: String, password: String) throws -> Int {
        try authenticate(username: username, password: password)
        try Self.ensureDirectory(at: databaseDirectoryURL)
        return try withDatabaseHandle { handle in
            try Self.schemaVersion(on: handle)
        }
    }

    func upsertMemoryRecord(_ record: MemoryRecord, applicationName: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO memory_sessions (
                application_name, session_id, agent_id, created_at, updated_at
            ) VALUES (
                \(quoted(applicationName)),
                \(quoted(record.pair.sessionID)),
                \(quoted(record.pair.agentID)),
                \(quoted(Self.iso8601Formatter().string(from: record.pair.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: record.pair.createdAt)))
            )
            ON CONFLICT(application_name, session_id, agent_id) DO UPDATE SET
                updated_at = excluded.updated_at;
            """, on: handle)

            try Self.execute("""
            INSERT INTO memory_records (
                id,
                application_name,
                session_id,
                agent_id,
                parent_agent_id,
                scope,
                created_at,
                prompt,
                completion,
                tool_calls_json,
                prompt_token_count,
                completion_token_count,
                compressed_summary_text,
                compressed_summary_keywords_json,
                compressed_summary_semantic_similarity,
                compressed_summary_compression_ratio,
                compressed_summary_source_token_count,
                compressed_summary_token_count,
                detailed_summary_text,
                detailed_summary_keywords_json,
                detailed_summary_semantic_similarity,
                detailed_summary_compression_ratio,
                detailed_summary_source_token_count,
                detailed_summary_token_count
            ) VALUES (
                \(quoted(record.id.uuidString)),
                \(quoted(applicationName)),
                \(quoted(record.pair.sessionID)),
                \(quoted(record.pair.agentID)),
                \(sqlValue(record.pair.parentAgentID)),
                \(quoted(record.scope.rawValue)),
                \(quoted(Self.iso8601Formatter().string(from: record.pair.createdAt))),
                \(quoted(record.pair.prompt)),
                \(quoted(record.pair.completion)),
                \(quoted(encodeJSON(record.pair.toolCalls) ?? "[]")),
                \(record.pair.promptTokenCount),
                \(record.pair.completionTokenCount),
                \(sqlValue(record.compressedSummary?.text)),
                \(sqlValue(encodeJSON(record.compressedSummary?.metadata.keywords))),
                \(sqlValue(record.compressedSummary?.metadata.semanticSimilarity)),
                \(sqlValue(record.compressedSummary?.metadata.compressionRatio)),
                \(sqlValue(record.compressedSummary?.metadata.sourceTokenCount)),
                \(sqlValue(record.compressedSummary?.metadata.summaryTokenCount)),
                \(sqlValue(record.detailedSummary?.text)),
                \(sqlValue(encodeJSON(record.detailedSummary?.metadata.keywords))),
                \(sqlValue(record.detailedSummary?.metadata.semanticSimilarity)),
                \(sqlValue(record.detailedSummary?.metadata.compressionRatio)),
                \(sqlValue(record.detailedSummary?.metadata.sourceTokenCount)),
                \(sqlValue(record.detailedSummary?.metadata.summaryTokenCount))
            )
            ON CONFLICT(id) DO UPDATE SET
                application_name = excluded.application_name,
                session_id = excluded.session_id,
                agent_id = excluded.agent_id,
                parent_agent_id = excluded.parent_agent_id,
                scope = excluded.scope,
                created_at = excluded.created_at,
                prompt = excluded.prompt,
                completion = excluded.completion,
                tool_calls_json = excluded.tool_calls_json,
                prompt_token_count = excluded.prompt_token_count,
                completion_token_count = excluded.completion_token_count,
                compressed_summary_text = excluded.compressed_summary_text,
                compressed_summary_keywords_json = excluded.compressed_summary_keywords_json,
                compressed_summary_semantic_similarity = excluded.compressed_summary_semantic_similarity,
                compressed_summary_compression_ratio = excluded.compressed_summary_compression_ratio,
                compressed_summary_source_token_count = excluded.compressed_summary_source_token_count,
                compressed_summary_token_count = excluded.compressed_summary_token_count,
                detailed_summary_text = excluded.detailed_summary_text,
                detailed_summary_keywords_json = excluded.detailed_summary_keywords_json,
                detailed_summary_semantic_similarity = excluded.detailed_summary_semantic_similarity,
                detailed_summary_compression_ratio = excluded.detailed_summary_compression_ratio,
                detailed_summary_source_token_count = excluded.detailed_summary_source_token_count,
                detailed_summary_token_count = excluded.detailed_summary_token_count;
            """, on: handle)
        }
    }

    func memoryRecord(id: UUID) throws -> MemoryRecord? {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT *
            FROM memory_records
            WHERE id = \(quoted(id.uuidString))
            LIMIT 1;
            """
            return try firstMemoryRecord(from: sql, on: handle)
        }
    }

    func memoryRecords(sessionKey: MemorySessionKey, applicationName: String, includeArchived: Bool = false) throws -> [MemoryRecord] {
        try withDatabaseHandle { handle in
            let retentionClause = Self.retentionSQLClause(includeArchived: includeArchived)
            let sql = """
            SELECT *
            FROM memory_records
            WHERE application_name = \(quoted(applicationName))
              AND session_id = \(quoted(sessionKey.sessionID))
              AND agent_id = \(quoted(sessionKey.agentID))
              \(retentionClause)
            ORDER BY created_at DESC;
            """
            return try allMemoryRecords(from: sql, on: handle)
        }
    }

    func searchMemoryRecords(
        sessionKey: MemorySessionKey,
        applicationName: String,
        query: String,
        limit: Int,
        includeArchived: Bool = false
    ) throws -> [MemoryRecord] {
        let pageSize = MemoryQueryPolicy.clampedRowLimit(limit)
        let tokens = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let records = try memoryRecords(sessionKey: sessionKey, applicationName: applicationName, includeArchived: includeArchived)
        let ranked = records
            .map { record in
                (record, Self.score(record: record, tokens: tokens))
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.pair.createdAt > rhs.0.pair.createdAt
                }
                return lhs.1 > rhs.1
            }
            .prefix(pageSize)

        return ranked.map(\.0)
    }

    func searchPriorMemoryRecords(
        sessionKey: MemorySessionKey,
        applicationName: String,
        query: String?,
        limit: Int,
        page: Int,
        includeArchived: Bool = false
    ) throws -> [MemoryRecord] {
        try withDatabaseHandle { handle in

            let pageSize = MemoryQueryPolicy.clampedRowLimit(limit)
            let pageIndex = max(page, 1)
            let offset = (pageIndex - 1) * pageSize

            let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
            let whereClause: String
            if let normalizedQuery, !normalizedQuery.isEmpty {
                let escaped = normalizedQuery.lowercased().replacingOccurrences(of: "'", with: "''")
                whereClause = """
                AND (
                    LOWER(prompt) LIKE '%\(escaped)%' OR
                    LOWER(completion) LIKE '%\(escaped)%' OR
                    LOWER(COALESCE(compressed_summary_text, '')) LIKE '%\(escaped)%' OR
                    LOWER(COALESCE(detailed_summary_text, '')) LIKE '%\(escaped)%' OR
                    LOWER(COALESCE(compressed_summary_keywords_json, '')) LIKE '%\(escaped)%' OR
                    LOWER(COALESCE(detailed_summary_keywords_json, '')) LIKE '%\(escaped)%'
                )
                """
            } else {
                whereClause = ""
            }

            let retentionClause = Self.retentionSQLClause(includeArchived: includeArchived)

            let sql = """
            SELECT *
            FROM memory_records
            WHERE application_name = \(quoted(applicationName))
              AND NOT (session_id = \(quoted(sessionKey.sessionID)) AND agent_id = \(quoted(sessionKey.agentID)))
              \(retentionClause)
              \(whereClause)
            ORDER BY created_at DESC
            LIMIT \(pageSize) OFFSET \(offset);
            """
            return try allMemoryRecords(from: sql, on: handle)
        }
    }

    func deleteMemoryRecord(id: UUID) throws {
        try withDatabaseHandle { handle in
            try Self.execute("DELETE FROM memory_records WHERE id = \(quoted(id.uuidString));", on: handle)
        }
    }

    func deleteMemorySession(_ sessionKey: MemorySessionKey, applicationName: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            DELETE FROM memory_sessions
            WHERE application_name = \(quoted(applicationName))
              AND session_id = \(quoted(sessionKey.sessionID))
              AND agent_id = \(quoted(sessionKey.agentID));
            """, on: handle)
        }
    }
}

extension DBRepository: MemoryStore {
    public func upsert(_ record: MemoryRecord) async throws {
        try upsertMemoryRecord(record, applicationName: applicationName)
    }

    public func record(id: UUID) async throws -> MemoryRecord? {
        try memoryRecord(id: id)
    }

    public func records(sessionKey: MemorySessionKey, includeArchived: Bool = false) async throws -> [MemoryRecord] {
        try memoryRecords(sessionKey: sessionKey, applicationName: applicationName, includeArchived: includeArchived)
    }

    public func search(
        sessionKey: MemorySessionKey,
        query: String,
        limit: Int,
        includeArchived: Bool = false
    ) async throws -> [MemoryRecord] {
        try searchMemoryRecords(
            sessionKey: sessionKey,
            applicationName: applicationName,
            query: query,
            limit: limit,
            includeArchived: includeArchived
        )
    }

    public func searchPrior(
        sessionKey: MemorySessionKey,
        query: String?,
        limit: Int,
        page: Int,
        includeArchived: Bool = false
    ) async throws -> [MemoryRecord] {
        try searchPriorMemoryRecords(
            sessionKey: sessionKey,
            applicationName: applicationName,
            query: query,
            limit: limit,
            page: page,
            includeArchived: includeArchived
        )
    }
}

extension DBRepository {
    static func retentionSQLClause(includeArchived: Bool, now: Date = .now) -> String {
        guard let cutoff = MemoryQueryPolicy.retentionCutoff(includeArchived: includeArchived, now: now) else {
            return ""
        }
        let iso = iso8601Formatter().string(from: cutoff)
        return "AND created_at >= '\(iso.replacingOccurrences(of: "'", with: "''"))'"
    }

    static func iso8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func schemaVersion(on handle: OpaquePointer) throws -> Int {
        let sql = "PRAGMA user_version;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Unable to read the schema version.")
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw Self.sqliteError(handle: handle, fallback: "Unable to read the schema version.")
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    static func applyMemoryMigration(version: Int, isUp: Bool, on handle: OpaquePointer) throws {
        let sql = try DatabaseSchema.migrationSQL(version: version, isUp: isUp)
        let appliedVersion = isUp ? version : version - 1

        do {
            try Self.execute("BEGIN IMMEDIATE TRANSACTION;", on: handle)
            // Execute the whole migration file (sqlite3_exec runs multiple statements).
            // Do not split on ';' — comments often contain semicolons and would break.
            try Self.execute(sql, on: handle)
            try Self.execute("PRAGMA user_version = \(appliedVersion);", on: handle)
            try Self.execute("COMMIT;", on: handle)
        } catch {
            _ = try? Self.execute("ROLLBACK;", on: handle)
            throw error
        }
    }

    static func score(record: MemoryRecord, tokens: [String]) -> Int {
        let rawText = [record.pair.prompt, record.pair.completion].joined(separator: " ").lowercased()
        let detailedText = record.detailedSummary?.text.lowercased() ?? ""
        let compressedText = record.compressedSummary?.text.lowercased() ?? ""
        let keywords = Set((record.detailedSummary?.metadata.keywords ?? []) + (record.compressedSummary?.metadata.keywords ?? []))

        return tokens.reduce(into: 0) { score, token in
            if keywords.contains(token) {
                score += 5
            }
            if compressedText.contains(token) {
                score += 4
            }
            if detailedText.contains(token) {
                score += 3
            }
            if rawText.contains(token) {
                score += 2
            }
        }
    }

    func firstMemoryRecord(from sql: String, on handle: OpaquePointer) throws -> MemoryRecord? {
        let records = try allMemoryRecords(from: sql, on: handle)
        return records.first
    }

    func allMemoryRecords(from sql: String, on handle: OpaquePointer) throws -> [MemoryRecord] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var records: [MemoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(try decodeMemoryRecord(statement: statement))
        }
        return records
    }

    func decodeMemoryRecord(statement: OpaquePointer) throws -> MemoryRecord {
        let id = try columnString(statement, index: 0)
        _ = try columnString(statement, index: 1)
        let sessionID = try columnString(statement, index: 2)
        let agentID = try columnString(statement, index: 3)
        let parentAgentID = columnOptionalString(statement, index: 4)
        let scopeRawValue = try columnString(statement, index: 5)
        let createdAtString = try columnString(statement, index: 6)
        let prompt = try columnString(statement, index: 7)
        let completion = try columnString(statement, index: 8)
        let toolCallsJSONString = try columnString(statement, index: 9)
        let promptTokenCount = Int(sqlite3_column_int(statement, 10))
        let completionTokenCount = Int(sqlite3_column_int(statement, 11))

        let pair = PromptResponsePair(
            id: UUID(uuidString: id) ?? UUID(),
            sessionID: sessionID,
            agentID: agentID,
            parentAgentID: parentAgentID,
            prompt: prompt,
            completion: completion,
            toolCalls: decodeToolCalls(from: toolCallsJSONString),
            createdAt: Self.iso8601Formatter().date(from: createdAtString) ?? .now,
            promptTokenCount: promptTokenCount,
            completionTokenCount: completionTokenCount
        )

        let compressedSummary = try decodeSummary(
            textColumn: 12,
            keywordsColumn: 13,
            semanticSimilarityColumn: 14,
            compressionRatioColumn: 15,
            sourceTokenCountColumn: 16,
            summaryTokenCountColumn: 17,
            statement: statement
        )

        let detailedSummary = try decodeSummary(
            textColumn: 18,
            keywordsColumn: 19,
            semanticSimilarityColumn: 20,
            compressionRatioColumn: 21,
            sourceTokenCountColumn: 22,
            summaryTokenCountColumn: 23,
            statement: statement
        )

        return MemoryRecord(
            id: UUID(uuidString: id) ?? UUID(),
            pair: pair,
            scope: MemoryAccessibility(rawValue: scopeRawValue) ?? .private,
            compressedSummary: compressedSummary,
            detailedSummary: detailedSummary
        )
    }

    func decodeSummary(
        textColumn: Int,
        keywordsColumn: Int,
        semanticSimilarityColumn: Int,
        compressionRatioColumn: Int,
        sourceTokenCountColumn: Int,
        summaryTokenCountColumn: Int,
        statement: OpaquePointer
    ) throws -> MemorySummary? {
        guard let text = columnOptionalString(statement, index: Int32(textColumn)) else {
            return nil
        }

        let keywords = decodeStringArray(columnOptionalString(statement, index: Int32(keywordsColumn)))
        let semanticSimilarity = columnOptionalDouble(statement, index: Int32(semanticSimilarityColumn))
        let compressionRatio = columnOptionalDouble(statement, index: Int32(compressionRatioColumn)) ?? 0
        let sourceTokenCount = Int(sqlite3_column_int(statement, Int32(sourceTokenCountColumn)))
        let summaryTokenCount = Int(sqlite3_column_int(statement, Int32(summaryTokenCountColumn)))

        return MemorySummary(
            text: text,
            metadata: MemorySummaryMetadata(
                keywords: keywords,
                semanticSimilarity: semanticSimilarity,
                compressionRatio: compressionRatio,
                sourceTokenCount: sourceTokenCount,
                summaryTokenCount: summaryTokenCount
            )
        )
    }

    func columnString(_ statement: OpaquePointer, index: Int32) throws -> String {
        guard let cString = sqlite3_column_text(statement, index) else {
            throw DBRepositoryError.sqliteOperationFailed("Missing required column at index \(index).")
        }

        return String(cString: cString)
    }

    func columnOptionalString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    func columnOptionalDouble(_ statement: OpaquePointer, index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    func decodeToolCalls(from json: String) -> [ToolCallRecord] {
        guard let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([ToolCallRecord].self, from: data)) ?? []
    }

    func decodeStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func encodeJSON<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func sqlValue(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return quoted(value)
    }

    func sqlValue(_ value: Double?) -> String {
        guard let value else { return "NULL" }
        return String(value)
    }

    func sqlValue(_ value: Int?) -> String {
        guard let value else { return "NULL" }
        return String(value)
    }

    func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
