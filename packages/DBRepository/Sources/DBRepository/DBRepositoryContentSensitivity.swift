import Foundation
import SQLite3

/// Permanent or session grant that skips content-confirm for a sensitivity category.
public struct ContentSensitivityGrant: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    /// Stable id: `email`, `phone`, `ssn`, …
    public var category: String
    /// `permanent` | `session`
    public var scope: String
    public var sessionID: String?
    public var actor: String?
    public var enabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        category: String,
        scope: String,
        sessionID: String? = nil,
        actor: String? = nil,
        enabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.category = category
        self.scope = scope
        self.sessionID = sessionID
        self.actor = actor
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension DBRepository {
    func loadContentSensitivityGrants(
        permanentOnly: Bool = false,
        sessionID: String? = nil,
        includeDisabled: Bool = false
    ) throws -> [ContentSensitivityGrant] {
        try withDatabaseHandle { handle in
            var clauses: [String] = []
            if !includeDisabled {
                clauses.append("enabled = 1")
            }
            if permanentOnly {
                clauses.append("scope = 'permanent'")
            } else if let sessionID {
                clauses.append("(scope = 'permanent' OR (scope = 'session' AND session_id = \(quoted(sessionID))))")
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = """
            SELECT id, category, scope, session_id, actor, enabled, created_at, updated_at
            FROM content_sensitivity_grants
            \(whereSQL)
            ORDER BY category ASC, scope ASC;
            """
            return try allContentSensitivityGrants(from: sql, on: handle)
        }
    }

    func saveContentSensitivityGrant(_ row: ContentSensitivityGrant) throws {
        try withDatabaseHandle { handle in
            if row.scope == "permanent" {
                // One active permanent grant per category.
                try Self.execute("""
                DELETE FROM content_sensitivity_grants
                WHERE category = \(quoted(row.category.lowercased()))
                  AND scope = 'permanent';
                """, on: handle)
            }
            try Self.execute("""
            INSERT INTO content_sensitivity_grants (
                id, category, scope, session_id, actor, enabled, created_at, updated_at
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.category.lowercased())),
                \(quoted(row.scope)),
                \(row.sessionID.map { quoted($0) } ?? "NULL"),
                \(row.actor.map { quoted($0) } ?? "NULL"),
                \(row.enabled ? 1 : 0),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: row.updatedAt)))
            );
            """, on: handle)
        }
    }

    func deleteContentSensitivityGrant(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute(
                "DELETE FROM content_sensitivity_grants WHERE id = \(quoted(id));",
                on: handle
            )
        }
    }

    func deletePermanentContentSensitivityGrant(category: String) throws {
        let cat = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try withDatabaseHandle { handle in
            try Self.execute("""
            DELETE FROM content_sensitivity_grants
            WHERE category = \(quoted(cat)) AND scope = 'permanent';
            """, on: handle)
        }
    }

    func deleteSessionContentSensitivityGrants(sessionID: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            DELETE FROM content_sensitivity_grants
            WHERE scope = 'session' AND session_id = \(quoted(sessionID));
            """, on: handle)
        }
    }

    private func allContentSensitivityGrants(from sql: String, on handle: OpaquePointer) throws -> [ContentSensitivityGrant] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBRepositoryError.sqliteOperationFailed("prepare content sensitivity grants failed")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [ContentSensitivityGrant] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idC = sqlite3_column_text(statement, 0),
                let categoryC = sqlite3_column_text(statement, 1),
                let scopeC = sqlite3_column_text(statement, 2)
            else { continue }
            let sessionID = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let actor = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let enabled = sqlite3_column_int(statement, 5) != 0
            let createdString = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let updatedString = sqlite3_column_text(statement, 7).map { String(cString: $0) }
            rows.append(
                ContentSensitivityGrant(
                    id: String(cString: idC),
                    category: String(cString: categoryC),
                    scope: String(cString: scopeC),
                    sessionID: sessionID,
                    actor: actor,
                    enabled: enabled,
                    createdAt: createdString.flatMap { Self.iso8601Formatter().date(from: $0) } ?? .now,
                    updatedAt: updatedString.flatMap { Self.iso8601Formatter().date(from: $0) } ?? .now
                )
            )
        }
        return rows
    }
}
