import Foundation
import SQLite3
import Structure

public extension DBRepository {
    func upsertHostUIPresent(pluginID: String, root: HostUINode) throws {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let data = try JSONEncoder().encode(root)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DBRepositoryError.sqliteOperationFailed("Could not encode host UI present tree.")
        }
        let updatedAt = Self.iso8601Formatter().string(from: .now)
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO plugin_host_ui (plugin_id, present_json, updated_at)
            VALUES (\(quoted(id)), \(quoted(json)), \(quoted(updatedAt)))
            ON CONFLICT(plugin_id) DO UPDATE SET
                present_json = excluded.present_json,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func hostUIPresent(pluginID: String) throws -> HostUINode? {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return try withDatabaseHandle { handle in
            let sql = """
            SELECT present_json FROM plugin_host_ui
            WHERE plugin_id = \(quoted(id))
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare host UI present load.")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let cString = sqlite3_column_text(statement, 0) else { return nil }
            let json = String(cString: cString)
            guard let data = json.data(using: .utf8) else { return nil }
            let node = try JSONDecoder().decode(HostUINode.self, from: data)
            try HostUILibraryStore.validate(node: node)
            return node
        }
    }

    func deleteHostUIPresent(pluginID: String) throws {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        try withDatabaseHandle { handle in
            try Self.execute("""
            DELETE FROM plugin_host_ui WHERE plugin_id = \(quoted(id));
            """, on: handle)
        }
    }
}

extension DBRepository: HostUIPresentPersisting {
    public func saveHostUIPresent(pluginID: String, root: HostUINode) async throws {
        try upsertHostUIPresent(pluginID: pluginID, root: root)
    }

    public func loadHostUIPresent(pluginID: String) async throws -> HostUINode? {
        try hostUIPresent(pluginID: pluginID)
    }
}
