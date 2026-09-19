import Foundation
import SQLite3
import Structure

/// Outcome of deleting a plugin (or one version) and its associated rows.
public struct PluginPurgeResult: Sendable, Equatable {
    public var pluginID: String
    public var removedReleaseCount: Int
    /// True when no factory releases remain for this plugin and associated data was purged.
    public var purgedAssociatedData: Bool
    public var removedMessagingConnectors: Int
    public var removedAgentHandled: Int
    public var removedChatSessions: Int
    public var removedWorkflowRuns: Int
    public var removedContentSensitivityGrants: Int
    public var removedHostUIPresents: Int

    public init(
        pluginID: String,
        removedReleaseCount: Int = 0,
        purgedAssociatedData: Bool = false,
        removedMessagingConnectors: Int = 0,
        removedAgentHandled: Int = 0,
        removedChatSessions: Int = 0,
        removedWorkflowRuns: Int = 0,
        removedContentSensitivityGrants: Int = 0,
        removedHostUIPresents: Int = 0
    ) {
        self.pluginID = pluginID
        self.removedReleaseCount = removedReleaseCount
        self.purgedAssociatedData = purgedAssociatedData
        self.removedMessagingConnectors = removedMessagingConnectors
        self.removedAgentHandled = removedAgentHandled
        self.removedChatSessions = removedChatSessions
        self.removedWorkflowRuns = removedWorkflowRuns
        self.removedContentSensitivityGrants = removedContentSensitivityGrants
        self.removedHostUIPresents = removedHostUIPresents
    }

    public var removedAnything: Bool {
        removedReleaseCount > 0
            || removedMessagingConnectors > 0
            || removedAgentHandled > 0
            || removedChatSessions > 0
            || removedWorkflowRuns > 0
            || removedContentSensitivityGrants > 0
            || removedHostUIPresents > 0
    }
}

public extension DBRepository {
    /// Deletes factory release row(s) and, when the plugin is fully gone, all associated
    /// messaging / chat / workflow / sensitivity rows in one SQLite transaction.
    @discardableResult
    func purgePlugin(pluginID: String, version: String? = nil) throws -> PluginPurgeResult {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DBRepositoryError.sqliteOperationFailed("Plugin id is required to purge.")
        }
        return try withDatabaseHandle { handle in
            try Self.withImmediateTransaction(on: handle) {
                try Self.purgePluginUnlocked(
                    pluginID: trimmed,
                    version: version?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    on: handle,
                    quoted: { self.quoted($0) }
                )
            }
        }
    }

    /// Removes messaging / chat / workflow leftovers whose plugin no longer has a factory release.
    @discardableResult
    func purgeOrphanedPluginAssociatedData() throws -> [PluginPurgeResult] {
        try withDatabaseHandle { handle in
            try Self.withImmediateTransaction(on: handle) {
                let live = try Self.pluginIDsWithReleases(on: handle, quoted: { self.quoted($0) })
                let candidates = try Self.pluginIDsWithAssociatedData(on: handle, quoted: { self.quoted($0) })
                let orphans = candidates.subtracting(live).sorted()
                var results: [PluginPurgeResult] = []
                for pluginID in orphans {
                    var result = try Self.purgeAssociatedDataUnlocked(
                        pluginID: pluginID,
                        on: handle,
                        quoted: { self.quoted($0) }
                    )
                    result.pluginID = pluginID
                    result.purgedAssociatedData = true
                    if result.removedAnything {
                        results.append(result)
                    }
                }
                return results
            }
        }
    }

    /// Lists plugin ids that still have factory releases.
    func listInstalledPluginIDs() throws -> Set<String> {
        try withDatabaseHandle { handle in
            try Self.pluginIDsWithReleases(on: handle, quoted: { self.quoted($0) })
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum PluginPurgeSQL {
    static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func sessionMatchSQL(pluginID: String, quoted: (String) -> String) -> String {
        let like = escapeLike(pluginID)
        let root = "plugin:\(like)"
        let thread = "plugin:\(like):thread:%"
        let messaging = "messaging-\(like)-%"
        let metaPluginID = "%\"pluginID\":\"\(like)\"%"
        let metaPlugin_id = "%\"plugin_id\":\"\(like)\"%"
        let title = "%/\(like)%"
        return """
        session_id = \(quoted("plugin:\(pluginID)"))
        OR session_id LIKE \(quoted(thread)) ESCAPE '\\'
        OR session_id LIKE \(quoted(messaging)) ESCAPE '\\'
        OR session_id LIKE \(quoted(root + "%")) ESCAPE '\\'
        OR metadata_json LIKE \(quoted(metaPluginID)) ESCAPE '\\'
        OR metadata_json LIKE \(quoted(metaPlugin_id)) ESCAPE '\\'
        OR IFNULL(title, '') LIKE \(quoted(title)) ESCAPE '\\'
        """
    }

    static func workflowMatchSQL(pluginID: String, quoted: (String) -> String) -> String {
        let like = escapeLike(pluginID)
        let patterns = [
            "%\"plugin_id\":\"\(like)\"%",
            "%\"pluginID\":\"\(like)\"%",
            "%plugin:\(like)%",
            "%/\(like)%",
        ]
        return patterns.map { pattern in
            """
            input_json LIKE \(quoted(pattern)) ESCAPE '\\'
            OR context_json LIKE \(quoted(pattern)) ESCAPE '\\'
            OR IFNULL(result_json, '') LIKE \(quoted(pattern)) ESCAPE '\\'
            OR IFNULL(error_message, '') LIKE \(quoted(pattern)) ESCAPE '\\'
            """
        }.joined(separator: " OR ")
    }
}

private extension DBRepository {
    static func purgePluginUnlocked(
        pluginID: String,
        version: String?,
        on handle: OpaquePointer,
        quoted: (String) -> String
    ) throws -> PluginPurgeResult {
        let beforeCount = try releaseCount(pluginID: pluginID, on: handle, quoted: quoted)
        guard beforeCount > 0 || version == nil else {
            // No releases for a versioned delete — still allow associated cleanup when version is nil.
            return PluginPurgeResult(pluginID: pluginID)
        }

        let versionClause = version.map { " AND version = \(quoted($0))" } ?? ""
        if beforeCount > 0 {
            try execute(
                """
                DELETE FROM plugin_factory_releases
                WHERE plugin_id = \(quoted(pluginID))\(versionClause);
                """,
                on: handle
            )
        }
        let afterCount = try releaseCount(pluginID: pluginID, on: handle, quoted: quoted)
        let removedReleases = max(0, beforeCount - afterCount)

        var result = PluginPurgeResult(
            pluginID: pluginID,
            removedReleaseCount: removedReleases
        )
        guard afterCount == 0 else {
            return result
        }

        let associated = try purgeAssociatedDataUnlocked(
            pluginID: pluginID,
            on: handle,
            quoted: quoted
        )
        result.purgedAssociatedData = true
        result.removedMessagingConnectors = associated.removedMessagingConnectors
        result.removedAgentHandled = associated.removedAgentHandled
        result.removedChatSessions = associated.removedChatSessions
        result.removedWorkflowRuns = associated.removedWorkflowRuns
        result.removedContentSensitivityGrants = associated.removedContentSensitivityGrants
        result.removedHostUIPresents = associated.removedHostUIPresents
        return result
    }

    static func purgeAssociatedDataUnlocked(
        pluginID: String,
        on handle: OpaquePointer,
        quoted: (String) -> String
    ) throws -> PluginPurgeResult {
        var result = PluginPurgeResult(pluginID: pluginID, purgedAssociatedData: true)

        result.removedHostUIPresents = try scalarCount(
            """
            SELECT COUNT(*) FROM plugin_host_ui
            WHERE plugin_id = \(quoted(pluginID));
            """,
            on: handle
        )
        try execute(
            """
            DELETE FROM plugin_host_ui
            WHERE plugin_id = \(quoted(pluginID));
            """,
            on: handle
        )

        result.removedAgentHandled = try scalarCount(
            """
            SELECT COUNT(*) FROM messaging_agent_handled
            WHERE plugin_id = \(quoted(pluginID));
            """,
            on: handle
        )
        try execute(
            """
            DELETE FROM messaging_agent_handled
            WHERE plugin_id = \(quoted(pluginID));
            """,
            on: handle
        )

        result.removedMessagingConnectors = try scalarCount(
            """
            SELECT COUNT(*) FROM messaging_connectors
            WHERE plugin_id = \(quoted(pluginID));
            """,
            on: handle
        )
        // Threads + messages cascade from connectors.
        try execute(
            """
            DELETE FROM messaging_connectors
            WHERE plugin_id = \(quoted(pluginID));
            """,
            on: handle
        )

        let sessionWhere = PluginPurgeSQL.sessionMatchSQL(pluginID: pluginID, quoted: quoted)
        result.removedChatSessions = try scalarCount(
            """
            SELECT COUNT(*) FROM chat_sessions
            WHERE \(sessionWhere);
            """,
            on: handle
        )
        result.removedContentSensitivityGrants = try scalarCount(
            """
            SELECT COUNT(*) FROM content_sensitivity_grants
            WHERE session_id IN (
                SELECT session_id FROM chat_sessions WHERE \(sessionWhere)
            );
            """,
            on: handle
        )
        try execute(
            """
            DELETE FROM content_sensitivity_grants
            WHERE session_id IN (
                SELECT session_id FROM chat_sessions WHERE \(sessionWhere)
            );
            """,
            on: handle
        )
        // agents / agent_turns cascade from chat_sessions.
        try execute(
            """
            DELETE FROM chat_sessions
            WHERE \(sessionWhere);
            """,
            on: handle
        )

        let workflowWhere = PluginPurgeSQL.workflowMatchSQL(pluginID: pluginID, quoted: quoted)
        result.removedWorkflowRuns = try scalarCount(
            """
            SELECT COUNT(*) FROM workflow_runs
            WHERE \(workflowWhere);
            """,
            on: handle
        )
        try execute(
            """
            DELETE FROM workflow_run_events
            WHERE workflow_id IN (
                SELECT id FROM workflow_runs WHERE \(workflowWhere)
            );
            """,
            on: handle
        )
        try execute(
            """
            DELETE FROM workflow_run_steps
            WHERE workflow_id IN (
                SELECT id FROM workflow_runs WHERE \(workflowWhere)
            );
            """,
            on: handle
        )
        try execute(
            """
            DELETE FROM workflow_runs
            WHERE \(workflowWhere);
            """,
            on: handle
        )

        return result
    }

    static func releaseCount(
        pluginID: String,
        on handle: OpaquePointer,
        quoted: (String) -> String
    ) throws -> Int {
        try scalarCount(
            """
            SELECT COUNT(*) FROM plugin_factory_releases
            WHERE plugin_id = \(quoted(pluginID));
            """,
            on: handle
        )
    }

    static func pluginIDsWithReleases(
        on handle: OpaquePointer,
        quoted: (String) -> String
    ) throws -> Set<String> {
        try stringSet(
            "SELECT DISTINCT plugin_id FROM plugin_factory_releases;",
            on: handle
        )
    }

    static func pluginIDsWithAssociatedData(
        on handle: OpaquePointer,
        quoted: (String) -> String
    ) throws -> Set<String> {
        var ids = try stringSet(
            "SELECT DISTINCT plugin_id FROM messaging_connectors;",
            on: handle
        )
        ids.formUnion(try stringSet(
            "SELECT DISTINCT plugin_id FROM messaging_agent_handled;",
            on: handle
        ))
        ids.formUnion(try stringSet(
            "SELECT DISTINCT plugin_id FROM plugin_host_ui;",
            on: handle
        ))
        // Chat / workflow orphans are harder to reverse-map; connector + handled cover messaging.
        // Also pick session_ids that look like plugin roots.
        let sessionSQL = """
        SELECT DISTINCT
            CASE
                WHEN session_id LIKE 'plugin:%:thread:%' THEN
                    substr(session_id, 8, instr(substr(session_id, 8), ':') - 1)
                WHEN session_id LIKE 'plugin:%' THEN
                    substr(session_id, 8)
                WHEN session_id LIKE 'messaging-%' THEN
                    -- messaging-<pluginID>-<uuid>-orchestrator
                    NULL
                ELSE NULL
            END
        FROM chat_sessions
        WHERE session_id LIKE 'plugin:%';
        """
        ids.formUnion(try stringSet(sessionSQL, on: handle).filter { !$0.isEmpty })

        // Parse messaging- orchestrator session ids in Swift-friendly second pass.
        let messagingSessions = try stringSet(
            """
            SELECT session_id FROM chat_sessions
            WHERE session_id LIKE 'messaging-%';
            """,
            on: handle
        )
        for sessionID in messagingSessions {
            if let pluginID = messagingOrchestratorPluginID(sessionID) {
                ids.insert(pluginID)
            }
        }
        return ids
    }

    /// `messaging-<pluginID>-<uuid>-orchestrator`
    static func messagingOrchestratorPluginID(_ sessionID: String) -> String? {
        guard sessionID.hasPrefix("messaging-"), sessionID.hasSuffix("-orchestrator") else {
            return nil
        }
        let body = String(sessionID.dropFirst("messaging-".count).dropLast("-orchestrator".count))
        // UUID is last 36 chars after a hyphen.
        guard body.count > 37, body[body.index(body.endIndex, offsetBy: -37)] == "-" else {
            return nil
        }
        let pluginID = String(body.dropLast(37))
        return pluginID.isEmpty ? nil : pluginID
    }

    static func scalarCount(_ sql: String, on handle: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(handle: handle, fallback: "Failed to count purge rows.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func stringSet(_ sql: String, on handle: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(handle: handle, fallback: "Failed to list plugin ids.")
        }
        defer { sqlite3_finalize(statement) }
        var values = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let c = sqlite3_column_text(statement, 0) else { continue }
            let value = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                values.insert(value)
            }
        }
        return values
    }
}
