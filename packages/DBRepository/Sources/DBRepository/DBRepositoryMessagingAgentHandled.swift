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

    func releaseMessagingAgentHandling(pluginID: String, vendorMessageID: String) throws {
        let trimmedPluginID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = vendorMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPluginID.isEmpty, !trimmedMessageID.isEmpty else { return }
        try withDatabaseHandle { handle in
            try Self.execute("""
            DELETE FROM messaging_agent_handled
            WHERE plugin_id = \(quoted(trimmedPluginID))
              AND vendor_message_id = \(quoted(trimmedMessageID));
            """, on: handle)
        }
    }

    /// Lets `$profile` inbound retry when a turn was claimed but never posted a reply.
    func releaseUnansweredProfileTokenClaims() throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            DELETE FROM messaging_agent_handled
            WHERE rowid IN (
                SELECT h.rowid
                FROM messaging_agent_handled h
                INNER JOIN messaging_threads t ON t.plugin_id = h.plugin_id
                INNER JOIN messaging_messages m
                  ON m.thread_id = t.id
                 AND m.vendor_message_id = h.vendor_message_id
                WHERE m.direction = \(quoted(MessagingMessageDirection.inbound.rawValue))
                  AND (
                    TRIM(m.body) LIKE '$%'
                    OR m.body LIKE '%$%'
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM messaging_messages o
                    WHERE o.thread_id = m.thread_id
                      AND o.direction = \(quoted(MessagingMessageDirection.outbound.rawValue))
                      AND o.created_at >= m.created_at
                  )
            );
            """, on: handle)
        }
    }
}
