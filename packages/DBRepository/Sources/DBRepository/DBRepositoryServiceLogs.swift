import Foundation
import SQLite3

public enum ServiceLogLevel: String, Codable, Sendable, Hashable {
    case debug
    case info
    case warning
    case error
}

public struct ServiceLogEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let service: String
    public let level: String
    public let code: String?
    public let message: String
    public let detailJSON: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        service: String,
        level: ServiceLogLevel,
        code: String? = nil,
        message: String,
        detailJSON: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.service = service
        self.level = level.rawValue
        self.code = code
        self.message = message
        self.detailJSON = detailJSON
        self.createdAt = createdAt
    }
}

public extension DBRepository {
    func appendServiceLog(_ entry: ServiceLogEntry) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO service_logs (id, service, level, code, message, detail_json, created_at)
            VALUES (
                \(quoted(entry.id)),
                \(quoted(entry.service)),
                \(quoted(entry.level)),
                \(sqlValue(entry.code)),
                \(quoted(entry.message)),
                \(sqlValue(entry.detailJSON)),
                \(quoted(Self.iso8601Formatter().string(from: entry.createdAt)))
            );
            """, on: handle)
        }
    }

    func recentServiceLogs(service: String? = nil, limit: Int = 100) throws -> [ServiceLogEntry] {
        let cap = max(1, min(limit, 5000))
        return try withDatabaseHandle { handle in
            let sql: String
            if let service, !service.isEmpty {
                sql = """
                SELECT id, service, level, code, message, detail_json, created_at
                FROM service_logs
                WHERE service = \(quoted(service))
                ORDER BY created_at DESC
                LIMIT \(cap);
                """
            } else {
                sql = """
                SELECT id, service, level, code, message, detail_json, created_at
                FROM service_logs
                ORDER BY created_at DESC
                LIMIT \(cap);
                """
            }
            return try Self.fetchServiceLogs(sql: sql, on: handle)
        }
    }

    /// Returns logs at or after `createdAfter`, oldest first (for tailing the debug log view).
    func serviceLogs(
        createdAfter: Date?,
        service: String? = nil,
        limit: Int = 500
    ) throws -> [ServiceLogEntry] {
        let cap = max(1, min(limit, 5000))
        return try withDatabaseHandle { handle in
            var clauses: [String] = []
            if let createdAfter {
                let stamp = quoted(Self.iso8601Formatter().string(from: createdAfter))
                clauses.append("created_at > \(stamp)")
            }
            if let service, !service.isEmpty {
                clauses.append("service = \(quoted(service))")
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))\n"
            let sql = """
            SELECT id, service, level, code, message, detail_json, created_at
            FROM service_logs
            \(whereSQL)ORDER BY created_at ASC
            LIMIT \(cap);
            """
            return try Self.fetchServiceLogs(sql: sql, on: handle)
        }
    }

    private static func fetchServiceLogs(sql: String, on handle: OpaquePointer) throws -> [ServiceLogEntry] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var entries: [ServiceLogEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let service = String(cString: sqlite3_column_text(statement, 1))
            let level = String(cString: sqlite3_column_text(statement, 2))
            let code: String? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(statement, 3))
            let message = String(cString: sqlite3_column_text(statement, 4))
            let detail: String? = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(statement, 5))
            let createdRaw = String(cString: sqlite3_column_text(statement, 6))
            let createdAt = iso8601Formatter().date(from: createdRaw) ?? .now
            entries.append(
                ServiceLogEntry(
                    id: id,
                    service: service,
                    level: ServiceLogLevel(rawValue: level) ?? .info,
                    code: code,
                    message: message,
                    detailJSON: detail,
                    createdAt: createdAt
                )
            )
        }
        return entries
    }
}
