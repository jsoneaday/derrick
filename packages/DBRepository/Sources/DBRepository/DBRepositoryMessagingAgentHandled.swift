import Foundation
import SQLite3
import Structure

public extension DBRepository {
    func claimMessagingAgentHandling(pluginID: String, vendorMessageID: String) throws -> Bool {
        let trimmedPluginID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = vendorMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPluginID.isEmpty, !trimmedMessageID.isEmpty else { return false }
        return try withDatabaseHandle { dbHandle in
            try Self.withImmediateTransaction(on: dbHandle) {
                var existsStatement: OpaquePointer?
                let existsSQL = """
                SELECT 1 FROM messaging_agent_handled
                WHERE plugin_id = \(quoted(trimmedPluginID))
                  AND vendor_message_id = \(quoted(trimmedMessageID))
                LIMIT 1;
                """
                guard sqlite3_prepare_v2(dbHandle, existsSQL, -1, &existsStatement, nil) == SQLITE_OK,
                      let existsStatement
                else {
                    throw Self.sqliteError(handle: dbHandle, fallback: "Failed to check messaging agent handled.")
                }
                defer { sqlite3_finalize(existsStatement) }
                if sqlite3_step(existsStatement) == SQLITE_ROW {
                    return false
                }

                try Self.execute("""
                INSERT INTO messaging_agent_handled (
                    plugin_id, vendor_message_id, handled_at
                ) VALUES (
                    \(quoted(trimmedPluginID)),
                    \(quoted(trimmedMessageID)),
                    \(quoted(Self.iso8601Formatter().string(from: .now)))
                );
                """, on: dbHandle)
                return true
            }
        }
    }
}
