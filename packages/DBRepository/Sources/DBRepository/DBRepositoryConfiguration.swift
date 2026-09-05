import Foundation
import SQLite3
import Structure

public extension DBRepository {
    func saveConfig(key: String, value: String, username: String, password: String) throws {
        try authenticate(username: username, password: password)
        try withDatabaseHandle { handle in
            let sql = """
            INSERT INTO configurations (key, value, updated_at)
            VALUES (\(quoted(key)), \(quoted(value)), CURRENT_TIMESTAMP)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = CURRENT_TIMESTAMP;
            """
            try Self.execute(sql, on: handle)
        }
    }

    func loadConfig(key: String, username: String, password: String) throws -> String? {
        try authenticate(username: username, password: password)
        return try withDatabaseHandle { handle in
            let sql = "SELECT value FROM configurations WHERE key = \(quoted(key)) LIMIT 1;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            if sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) {
                return String(cString: cString)
            }
            return nil
        }
    }
}