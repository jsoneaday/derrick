import Foundation
import SQLite3
import Structure

public extension DBRepository {
    func upsertAgentProfile(_ profile: AgentProfile) throws {
        let ragData = try JSONEncoder().encode(profile.rag)
        let ragJSON = String(data: ragData, encoding: .utf8) ?? "{}"
        let modelJSON = String(data: profile.modelJSON, encoding: .utf8) ?? "{}"
        let thinkingJSON = profile.thinkingJSON.flatMap { String(data: $0, encoding: .utf8) }
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO agent_profiles (
                id, display_name, handle, instructions, model_json, thinking_json, rag_json,
                is_enabled, is_builtin, sort_order, created_at, updated_at
            ) VALUES (
                \(quoted(profile.id)),
                \(quoted(profile.displayName)),
                \(quoted(profile.handle)),
                \(quoted(profile.instructions)),
                \(quoted(modelJSON)),
                \(sqlValue(thinkingJSON)),
                \(quoted(ragJSON)),
                \(profile.isEnabled ? 1 : 0),
                \(profile.isBuiltin ? 1 : 0),
                \(profile.sortOrder),
                \(quoted(Self.iso8601Formatter().string(from: profile.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: profile.updatedAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                handle = excluded.handle,
                instructions = excluded.instructions,
                model_json = excluded.model_json,
                thinking_json = excluded.thinking_json,
                rag_json = excluded.rag_json,
                is_enabled = excluded.is_enabled,
                is_builtin = excluded.is_builtin,
                sort_order = excluded.sort_order,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func listAgentProfiles() throws -> [AgentProfile] {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT id, display_name, handle, instructions, model_json, thinking_json, rag_json,
                   is_enabled, is_builtin, sort_order, created_at, updated_at
            FROM agent_profiles
            ORDER BY sort_order ASC, display_name ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to list agent profiles.")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [AgentProfile] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeAgentProfile(statement: statement))
            }
            return rows
        }
    }

    func agentProfile(id: String) throws -> AgentProfile? {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT id, display_name, handle, instructions, model_json, thinking_json, rag_json,
                   is_enabled, is_builtin, sort_order, created_at, updated_at
            FROM agent_profiles
            WHERE id = \(quoted(id))
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to load agent profile.")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeAgentProfile(statement: statement)
        }
    }

    func agentProfile(handle: String) throws -> AgentProfile? {
        let normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try withDatabaseHandle { dbHandle in
            let sql = """
            SELECT id, display_name, handle, instructions, model_json, thinking_json, rag_json,
                   is_enabled, is_builtin, sort_order, created_at, updated_at
            FROM agent_profiles
            WHERE handle = \(quoted(normalized))
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: dbHandle, fallback: "Failed to load agent profile by handle.")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeAgentProfile(statement: statement)
        }
    }

    func deleteAgentProfile(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute(
                "DELETE FROM agent_profiles WHERE id = \(quoted(id)) AND is_builtin = 0;",
                on: handle
            )
        }
    }

    private func decodeAgentProfile(statement: OpaquePointer) throws -> AgentProfile {
        func text(_ index: Int32) -> String {
            String(cString: sqlite3_column_text(statement, index))
        }
        func optionalText(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(index)
        }
        let rag = (try? JSONDecoder().decode(
            AgentProfileRAGConfig.self,
            from: Data(text(6).utf8)
        )) ?? .default
        return AgentProfile(
            id: text(0),
            displayName: text(1),
            handle: text(2),
            instructions: text(3),
            modelJSON: Data(text(4).utf8),
            thinkingJSON: optionalText(5).map { Data($0.utf8) },
            rag: rag,
            isEnabled: sqlite3_column_int(statement, 7) != 0,
            isBuiltin: sqlite3_column_int(statement, 8) != 0,
            sortOrder: Int(sqlite3_column_int(statement, 9)),
            createdAt: Self.iso8601Formatter().date(from: text(10)) ?? .now,
            updatedAt: Self.iso8601Formatter().date(from: text(11)) ?? .now
        )
    }
}
