import Foundation
import SQLite3

/// One permanently stored domain suffix allowed by the egress proxy.
public struct EgressAllowedDomainSuffix: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var suffix: String
    /// `seed` | `user`
    public var source: String
    public var enabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        suffix: String,
        source: String,
        enabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.suffix = suffix
        self.source = source
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

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
