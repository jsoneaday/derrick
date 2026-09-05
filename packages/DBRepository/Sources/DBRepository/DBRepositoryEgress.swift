import Foundation
import SQLite3
import Plugin
import Structure

public extension DBRepository {
    func loadEgressAllowedDomainSuffixes(includeDisabled: Bool = false) throws -> [EgressAllowedDomainSuffix] {
        try withDatabaseHandle { handle in
            let filter = includeDisabled ? "" : "WHERE enabled = 1"
            let sql = """
            SELECT id, suffix, source, enabled, created_at, updated_at
            FROM egress_allowed_domain_suffixes
            \(filter)
            ORDER BY suffix ASC;
            """
            return try allEgressSuffixes(from: sql, on: handle)
        }
    }

    func saveEgressAllowedDomainSuffix(_ row: EgressAllowedDomainSuffix) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO egress_allowed_domain_suffixes (
                id, suffix, source, enabled, created_at, updated_at
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.suffix.lowercased())),
                \(quoted(row.source)),
                \(row.enabled ? 1 : 0),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: row.updatedAt)))
            )
            ON CONFLICT(suffix) DO UPDATE SET
                source = excluded.source,
                enabled = excluded.enabled,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func deleteEgressAllowedDomainSuffix(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute(
                "DELETE FROM egress_allowed_domain_suffixes WHERE id = \(quoted(id));",
                on: handle
            )
        }
    }

    func deleteEgressAllowedDomainSuffix(suffix: String) throws {
        let normalized = suffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try withDatabaseHandle { handle in
            try Self.execute(
                "DELETE FROM egress_allowed_domain_suffixes WHERE suffix = \(quoted(normalized));",
                on: handle
            )
        }
    }

    /// Inserts seed suffixes that are not already present. Returns count inserted.
    func seedEgressAllowedDomainSuffixesIfNeeded(_ suffixes: [String], source: String = "seed") throws -> Int {
        let existing = try Set(loadEgressAllowedDomainSuffixes(includeDisabled: true).map(\.suffix))
        var inserted = 0
        for raw in suffixes {
            let suffix = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !suffix.isEmpty, !existing.contains(suffix) else { continue }
            try saveEgressAllowedDomainSuffix(
                EgressAllowedDomainSuffix(suffix: suffix, source: source, enabled: true)
            )
            inserted += 1
        }
        return inserted
    }

    func listEgressBlacklist() throws -> [BlacklistEntry] {
        try loadBlacklistTable("egress_blacklist")
    }

    func listEgressBlacklistExceptions() throws -> [BlacklistEntry] {
        try loadBlacklistTable("egress_blacklist_exceptions")
    }

    func addEgressBlacklistEntry(_ entry: BlacklistEntry) throws {
        try insertBlacklistRow(table: "egress_blacklist", entry: entry)
    }

    func addEgressBlacklistException(_ entry: BlacklistEntry) throws {
        try insertBlacklistRow(table: "egress_blacklist_exceptions", entry: entry)
    }

    func deleteEgressBlacklistEntry(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("DELETE FROM egress_blacklist WHERE id = \(quoted(id));", on: handle)
        }
    }

    func deleteEgressBlacklistException(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute(
                "DELETE FROM egress_blacklist_exceptions WHERE id = \(quoted(id));",
                on: handle
            )
        }
    }

    private func insertBlacklistRow(table: String, entry: BlacklistEntry) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO \(table) (id, pattern, kind, created_at)
            VALUES (
                \(quoted(entry.id)),
                \(quoted(entry.pattern)),
                \(quoted(entry.kind.rawValue)),
                \(quoted(Self.iso8601Formatter().string(from: .now)))
            )
            ON CONFLICT(kind, pattern) DO NOTHING;
            """, on: handle)
        }
    }

    private func loadBlacklistTable(_ table: String) throws -> [BlacklistEntry] {
        try withDatabaseHandle { handle in
            let sql = "SELECT id, pattern, kind FROM \(table) ORDER BY pattern ASC;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw DBRepositoryError.sqliteOperationFailed("prepare \(table) failed")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [BlacklistEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let idC = sqlite3_column_text(statement, 0),
                    let patternC = sqlite3_column_text(statement, 1),
                    let kindC = sqlite3_column_text(statement, 2),
                    let kind = BlacklistEntryKind(rawValue: String(cString: kindC))
                else { continue }
                rows.append(
                    BlacklistEntry(
                        id: String(cString: idC),
                        kind: kind,
                        pattern: String(cString: patternC)
                    )
                )
            }
            return rows
        }
    }

    private func allEgressSuffixes(from sql: String, on handle: OpaquePointer) throws -> [EgressAllowedDomainSuffix] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBRepositoryError.sqliteOperationFailed("prepare egress suffixes failed")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [EgressAllowedDomainSuffix] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idC = sqlite3_column_text(statement, 0),
                let suffixC = sqlite3_column_text(statement, 1),
                let sourceC = sqlite3_column_text(statement, 2)
            else { continue }
            let enabled = sqlite3_column_int(statement, 3) != 0
            let createdString = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let updatedString = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            rows.append(
                EgressAllowedDomainSuffix(
                    id: String(cString: idC),
                    suffix: String(cString: suffixC),
                    source: String(cString: sourceC),
                    enabled: enabled,
                    createdAt: createdString.flatMap { Self.iso8601Formatter().date(from: $0) } ?? .now,
                    updatedAt: updatedString.flatMap { Self.iso8601Formatter().date(from: $0) } ?? .now
                )
            )
        }
        return rows
    }
}
