import Foundation
import SQLite3
import AgentRuntime
import ServiceContracts

public extension DBRepository {
    // MARK: - Chat sessions

    func upsertChatSession(_ session: ChatSessionDTO) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO chat_sessions (
                application_name,
                session_id,
                title,
                created_at,
                updated_at,
                metadata_json
            ) VALUES (
                \(quoted(session.applicationName)),
                \(quoted(session.sessionID)),
                \(sqlValue(session.title)),
                \(quoted(Self.iso8601Formatter().string(from: session.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: session.updatedAt))),
                \(quoted(encodeJSON(session.metadata) ?? "{}"))
            )
            ON CONFLICT(application_name, session_id) DO UPDATE SET
                title = COALESCE(excluded.title, chat_sessions.title),
                updated_at = excluded.updated_at,
                metadata_json = excluded.metadata_json;
            """, on: handle)
        }
    }

    func touchChatSessionUpdated(applicationName: String, sessionID: String, at date: Date = .now) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE chat_sessions
            SET updated_at = \(quoted(Self.iso8601Formatter().string(from: date)))
            WHERE application_name = \(quoted(applicationName))
              AND session_id = \(quoted(sessionID));
            """, on: handle)
        }
    }

    func listRecentChatSessions(applicationName: String, limit: Int = 5) throws -> [ChatSessionDTO] {
        try withDatabaseHandle { handle in
            // Job-isolated sessions (`job-<uuid>`) must never appear in the interactive chat list —
            // selecting one queues live turns behind hung background wakes.
            let sql = """
            SELECT application_name, session_id, title, created_at, updated_at, metadata_json
            FROM chat_sessions
            WHERE application_name = \(quoted(applicationName))
              AND session_id NOT LIKE 'job-%'
              AND session_id NOT LIKE 'factory-%'
            ORDER BY updated_at DESC
            LIMIT \(max(1, limit));
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare chat session list.")
            }
            defer { sqlite3_finalize(statement) }

            var sessions: [ChatSessionDTO] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                sessions.append(try decodeChatSession(statement: statement))
            }
            return sessions
        }
    }

    func updateChatSessionTitle(
        applicationName: String,
        sessionID: String,
        title: String,
        updatedAt: Date = .now
    ) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE chat_sessions
            SET title = \(quoted(trimmed)),
                updated_at = \(quoted(Self.iso8601Formatter().string(from: updatedAt)))
            WHERE application_name = \(quoted(applicationName))
              AND session_id = \(quoted(sessionID));
            """, on: handle)
        }
    }

    // MARK: - Agents

    func upsertAgentRecord(_ record: AgentRecord, applicationName: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO agents (
                application_name,
                session_id,
                agent_id,
                role,
                parent_agent_id,
                status,
                goal,
                system_overlay,
                model_preference,
                created_at,
                updated_at,
                metadata_json
            ) VALUES (
                \(quoted(applicationName)),
                \(quoted(record.ref.sessionID)),
                \(quoted(record.ref.agentID)),
                \(quoted(record.role.rawValue)),
                \(sqlValue(record.parentAgentID)),
                \(quoted(record.status.rawValue)),
                \(sqlValue(record.goal)),
                \(sqlValue(record.systemOverlay)),
                \(sqlValue(record.modelPreference)),
                \(quoted(Self.iso8601Formatter().string(from: record.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: record.updatedAt))),
                \(quoted(encodeJSON(record.metadata) ?? "{}"))
            )
            ON CONFLICT(application_name, session_id, agent_id) DO UPDATE SET
                role = excluded.role,
                parent_agent_id = excluded.parent_agent_id,
                status = excluded.status,
                goal = excluded.goal,
                system_overlay = excluded.system_overlay,
                model_preference = excluded.model_preference,
                updated_at = excluded.updated_at,
                metadata_json = excluded.metadata_json;
            """, on: handle)
        }
    }

    func updateAgentStatus(
        ref: AgentRef,
        applicationName: String,
        status: AgentStatus,
        updatedAt: Date = .now
    ) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE agents
            SET status = \(quoted(status.rawValue)),
                updated_at = \(quoted(Self.iso8601Formatter().string(from: updatedAt)))
            WHERE application_name = \(quoted(applicationName))
              AND session_id = \(quoted(ref.sessionID))
              AND agent_id = \(quoted(ref.agentID));
            """, on: handle)
        }
    }

    func loadAgentRecords(applicationName: String, sessionID: String) throws -> [AgentRecord] {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT
                session_id,
                agent_id,
                role,
                parent_agent_id,
                status,
                goal,
                system_overlay,
                model_preference,
                created_at,
                updated_at,
                metadata_json
            FROM agents
            WHERE application_name = \(quoted(applicationName))
              AND session_id = \(quoted(sessionID))
            ORDER BY created_at ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare agent list.")
            }
            defer { sqlite3_finalize(statement) }

            var records: [AgentRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                records.append(try decodeAgentRecord(statement: statement))
            }
            return records
        }
    }

    // MARK: - Agent turns

    func insertAgentTurn(_ turn: AgentTurnRowDTO) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO agent_turns (
                id,
                application_name,
                session_id,
                agent_id,
                correlation_id,
                envelope_kind,
                status,
                prompt_preview,
                created_at,
                updated_at
            ) VALUES (
                \(quoted(turn.id)),
                \(quoted(turn.applicationName)),
                \(quoted(turn.sessionID)),
                \(quoted(turn.agentID)),
                \(sqlValue(turn.correlationID)),
                \(quoted(turn.envelopeKind)),
                \(quoted(turn.status.rawValue)),
                \(sqlValue(turn.promptPreview)),
                \(quoted(Self.iso8601Formatter().string(from: turn.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: turn.updatedAt)))
            );
            """, on: handle)
        }
    }

    func updateAgentTurnStatus(
        id: String,
        status: AgentTurnStatus,
        updatedAt: Date = .now
    ) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE agent_turns
            SET status = \(quoted(status.rawValue)),
                updated_at = \(quoted(Self.iso8601Formatter().string(from: updatedAt)))
            WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    // MARK: - Decoding

    private func decodeChatSession(statement: OpaquePointer) throws -> ChatSessionDTO {
        let applicationName = try columnString(statement, index: 0)
        let sessionID = try columnString(statement, index: 1)
        let title = columnOptionalString(statement, index: 2)
        let createdAt = Self.iso8601Formatter().date(from: try columnString(statement, index: 3)) ?? .now
        let updatedAt = Self.iso8601Formatter().date(from: try columnString(statement, index: 4)) ?? .now
        let metadataJSON = columnOptionalString(statement, index: 5) ?? "{}"
        let metadata = decodeStringDictionary(metadataJSON)
        return ChatSessionDTO(
            applicationName: applicationName,
            sessionID: sessionID,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: metadata
        )
    }

    private func decodeAgentRecord(statement: OpaquePointer) throws -> AgentRecord {
        let sessionID = try columnString(statement, index: 0)
        let agentID = try columnString(statement, index: 1)
        let roleRaw = try columnString(statement, index: 2)
        let parentAgentID = columnOptionalString(statement, index: 3)
        let statusRaw = try columnString(statement, index: 4)
        let goal = columnOptionalString(statement, index: 5)
        let systemOverlay = columnOptionalString(statement, index: 6)
        let modelPreference = columnOptionalString(statement, index: 7)
        let createdAt = Self.iso8601Formatter().date(from: try columnString(statement, index: 8)) ?? .now
        let updatedAt = Self.iso8601Formatter().date(from: try columnString(statement, index: 9)) ?? .now
        let metadataJSON = columnOptionalString(statement, index: 10) ?? "{}"
        let metadata = decodeStringDictionary(metadataJSON)

        return AgentRecord(
            ref: AgentRef(sessionID: sessionID, agentID: agentID),
            role: AgentRole(rawValue: roleRaw) ?? .worker,
            parentAgentID: parentAgentID,
            status: AgentStatus(rawValue: statusRaw) ?? .idle,
            goal: goal,
            systemOverlay: systemOverlay,
            modelPreference: modelPreference,
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: metadata
        )
    }

    private func decodeStringDictionary(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return dict
    }
}
