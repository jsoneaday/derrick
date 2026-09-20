import Foundation
import SQLite3
import Structure

public extension DBRepository {
    func upsertMessagingAgentWork(_ work: MessagingAgentWorkInFlight) throws {
        let pluginID = work.pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = work.threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = work.parentVendorMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = work.profileHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = work.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pluginID.isEmpty, !threadID.isEmpty, !parent.isEmpty, !handle.isEmpty else { return }
        let displayName = name.isEmpty ? handle : name
        try withDatabaseHandle { dbHandle in
            try Self.execute("""
            INSERT INTO messaging_agent_work (
                plugin_id, thread_id, parent_vendor_message_id,
                profile_handle, display_name, started_at
            ) VALUES (
                \(quoted(pluginID)),
                \(quoted(threadID)),
                \(quoted(parent)),
                \(quoted(handle)),
                \(quoted(displayName)),
                \(quoted(Self.iso8601Formatter().string(from: .now)))
            )
            ON CONFLICT(plugin_id, thread_id, parent_vendor_message_id) DO UPDATE SET
                profile_handle = excluded.profile_handle,
                display_name = excluded.display_name,
                started_at = excluded.started_at;
            """, on: dbHandle)
        }
    }

    func clearMessagingAgentWork(
        pluginID: String,
        threadID: String,
        parentVendorMessageID: String
    ) throws {
        let pluginID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = parentVendorMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pluginID.isEmpty, !threadID.isEmpty, !parent.isEmpty else { return }
        try withDatabaseHandle { dbHandle in
            try Self.execute("""
            DELETE FROM messaging_agent_work
            WHERE plugin_id = \(quoted(pluginID))
              AND thread_id = \(quoted(threadID))
              AND parent_vendor_message_id = \(quoted(parent));
            """, on: dbHandle)
        }
    }

    func listMessagingAgentWork(threadID: String) throws -> [MessagingAgentWorkInFlight] {
        let threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else { return [] }
        return try withDatabaseHandle { dbHandle in
            let sql = """
            SELECT plugin_id, thread_id, parent_vendor_message_id, profile_handle, display_name
            FROM messaging_agent_work
            WHERE thread_id = \(quoted(threadID))
            ORDER BY started_at ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: dbHandle, fallback: "Failed to list messaging agent work.")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [MessagingAgentWorkInFlight] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    MessagingAgentWorkInFlight(
                        pluginID: try columnString(statement, index: 0),
                        threadID: try columnString(statement, index: 1),
                        parentVendorMessageID: try columnString(statement, index: 2),
                        profileHandle: try columnString(statement, index: 3),
                        displayName: try columnString(statement, index: 4)
                    )
                )
            }
            return rows
        }
    }
}
