import Foundation
import SQLite3
import Plugin

public struct PluginRow: Sendable, Hashable {
    public var id: String
    public var enabled: Bool
    public var currentVersionID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        enabled: Bool = true,
        currentVersionID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.enabled = enabled
        self.currentVersionID = currentVersionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PluginVersionRow: Sendable, Hashable {
    public var id: String
    public var pluginID: String
    public var version: String
    public var contentHash: String
    public var status: String
    public var volumeName: String?
    public var manifestJSON: String
    public var runtimeJSON: String?
    public var dependenciesJSON: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        pluginID: String,
        version: String,
        contentHash: String,
        status: String,
        volumeName: String? = nil,
        manifestJSON: String,
        runtimeJSON: String? = nil,
        dependenciesJSON: String = "{}",
        createdAt: Date = .now
    ) {
        self.id = id
        self.pluginID = pluginID
        self.version = version
        self.contentHash = contentHash
        self.status = status
        self.volumeName = volumeName
        self.manifestJSON = manifestJSON
        self.runtimeJSON = runtimeJSON
        self.dependenciesJSON = dependenciesJSON
        self.createdAt = createdAt
    }
}

public struct PluginGrantRow: Sendable, Hashable {
    public var id: String
    public var pluginID: String
    public var versionID: String
    public var authRefsJSON: String
    public var attachHostsJSON: String
    public var notifySessionID: String?
    public var dependenciesJSON: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        pluginID: String,
        versionID: String,
        authRefsJSON: String = "[]",
        attachHostsJSON: String = "[]",
        notifySessionID: String? = nil,
        dependenciesJSON: String = "{}",
        createdAt: Date = .now
    ) {
        self.id = id
        self.pluginID = pluginID
        self.versionID = versionID
        self.authRefsJSON = authRefsJSON
        self.attachHostsJSON = attachHostsJSON
        self.notifySessionID = notifySessionID
        self.dependenciesJSON = dependenciesJSON
        self.createdAt = createdAt
    }
}

public struct PluginInvokeRow: Sendable, Hashable {
    public var id: String
    public var pluginID: String?
    public var versionID: String?
    public var invokeID: String
    public var kind: String
    public var status: String
    public var hop: Int
    public var principalJSON: String
    public var resultJSON: String?
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        pluginID: String?,
        versionID: String?,
        invokeID: String,
        kind: String,
        status: String,
        hop: Int = 0,
        principalJSON: String,
        resultJSON: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.pluginID = pluginID
        self.versionID = versionID
        self.invokeID = invokeID
        self.kind = kind
        self.status = status
        self.hop = hop
        self.principalJSON = principalJSON
        self.resultJSON = resultJSON
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PendingPluginWaitRow: Sendable, Hashable {
    public var id: String
    public var invokeID: String
    public var pluginID: String?
    public var kind: String
    public var payloadJSON: String
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        id: String = UUID().uuidString,
        invokeID: String,
        pluginID: String? = nil,
        kind: String,
        payloadJSON: String,
        createdAt: Date = .now,
        expiresAt: Date
    ) {
        self.id = id
        self.invokeID = invokeID
        self.pluginID = pluginID
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct FactorySessionRow: Sendable, Hashable {
    public var sessionID: String
    public var specJSON: String?
    public var stage: String
    public var pluginID: String?
    public var reviewerCalls: Int
    public var harnessRuns: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        sessionID: String,
        specJSON: String? = nil,
        stage: String,
        pluginID: String? = nil,
        reviewerCalls: Int = 0,
        harnessRuns: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.sessionID = sessionID
        self.specJSON = specJSON
        self.stage = stage
        self.pluginID = pluginID
        self.reviewerCalls = reviewerCalls
        self.harnessRuns = harnessRuns
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension DBRepository {
    func upsertPlugin(_ row: PluginRow) throws {
        _ = try PluginID(row.id)
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO plugins (id, enabled, current_version_id, created_at, updated_at)
            VALUES (
                \(quoted(row.id)),
                \(row.enabled ? 1 : 0),
                \(sqlValue(row.currentVersionID)),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: row.updatedAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                enabled = excluded.enabled,
                current_version_id = excluded.current_version_id,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func listPlugins(includeDisabled: Bool = true) throws -> [PluginRow] {
        try withDatabaseHandle { handle in
            let filter = includeDisabled ? "" : "WHERE enabled = 1"
            return try allPluginRows(
                from: "SELECT id, enabled, current_version_id, created_at, updated_at FROM plugins \(filter) ORDER BY id ASC;",
                on: handle
            )
        }
    }

    func setPluginEnabled(id: String, enabled: Bool, updatedAt: Date = .now) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE plugins
            SET enabled = \(enabled ? 1 : 0),
                updated_at = \(quoted(Self.iso8601Formatter().string(from: updatedAt)))
            WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    /// Deletes the plugin row. Invoke history is kept (`plugin_id` SET NULL).
    func deletePlugin(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("DELETE FROM plugins WHERE id = \(quoted(id));", on: handle)
        }
    }

    func upsertPluginVersion(_ row: PluginVersionRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO plugin_versions (
                id, plugin_id, version, content_hash, status, volume_name,
                manifest_json, runtime_json, dependencies_json, created_at
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.pluginID)),
                \(quoted(row.version)),
                \(quoted(row.contentHash)),
                \(quoted(row.status)),
                \(sqlValue(row.volumeName)),
                \(quoted(row.manifestJSON)),
                \(sqlValue(row.runtimeJSON)),
                \(quoted(row.dependenciesJSON)),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                status = excluded.status,
                volume_name = excluded.volume_name,
                manifest_json = excluded.manifest_json,
                runtime_json = excluded.runtime_json,
                dependencies_json = excluded.dependencies_json;
            """, on: handle)
        }
    }

    func listPluginVersions(pluginID: String) throws -> [PluginVersionRow] {
        try withDatabaseHandle { handle in
            try allPluginVersionRows(
                from: """
                SELECT id, plugin_id, version, content_hash, status, volume_name,
                       manifest_json, runtime_json, dependencies_json, created_at
                FROM plugin_versions
                WHERE plugin_id = \(quoted(pluginID))
                ORDER BY created_at DESC;
                """,
                on: handle
            )
        }
    }

    func upsertPluginGrant(_ row: PluginGrantRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO plugin_grants (
                id, plugin_id, version_id, auth_refs_json, attach_hosts_json,
                notify_session_id, dependencies_json, created_at
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.pluginID)),
                \(quoted(row.versionID)),
                \(quoted(row.authRefsJSON)),
                \(quoted(row.attachHostsJSON)),
                \(sqlValue(row.notifySessionID)),
                \(quoted(row.dependenciesJSON)),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                auth_refs_json = excluded.auth_refs_json,
                attach_hosts_json = excluded.attach_hosts_json,
                notify_session_id = excluded.notify_session_id,
                dependencies_json = excluded.dependencies_json;
            """, on: handle)
        }
    }

    func listPluginGrants(pluginID: String) throws -> [PluginGrantRow] {
        try withDatabaseHandle { handle in
            try allPluginGrantRows(
                from: """
                SELECT id, plugin_id, version_id, auth_refs_json, attach_hosts_json,
                       notify_session_id, dependencies_json, created_at
                FROM plugin_grants
                WHERE plugin_id = \(quoted(pluginID))
                ORDER BY created_at DESC;
                """,
                on: handle
            )
        }
    }

    func upsertPluginInvoke(_ row: PluginInvokeRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO plugin_invokes (
                id, plugin_id, version_id, invoke_id, kind, status, hop,
                principal_json, result_json, error_message, created_at, updated_at
            ) VALUES (
                \(quoted(row.id)),
                \(sqlValue(row.pluginID)),
                \(sqlValue(row.versionID)),
                \(quoted(row.invokeID)),
                \(quoted(row.kind)),
                \(quoted(row.status)),
                \(row.hop),
                \(quoted(row.principalJSON)),
                \(sqlValue(row.resultJSON)),
                \(sqlValue(row.errorMessage)),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: row.updatedAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                plugin_id = excluded.plugin_id,
                version_id = excluded.version_id,
                status = excluded.status,
                hop = excluded.hop,
                result_json = excluded.result_json,
                error_message = excluded.error_message,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func pluginInvoke(invokeID: String) throws -> PluginInvokeRow? {
        try withDatabaseHandle { handle in
            try allPluginInvokeRows(
                from: """
                SELECT id, plugin_id, version_id, invoke_id, kind, status, hop,
                       principal_json, result_json, error_message, created_at, updated_at
                FROM plugin_invokes
                WHERE invoke_id = \(quoted(invokeID))
                LIMIT 1;
                """,
                on: handle
            ).first
        }
    }

    func upsertPendingPluginWait(_ row: PendingPluginWaitRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO pending_plugin_waits (
                id, invoke_id, plugin_id, kind, payload_json, created_at, expires_at
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.invokeID)),
                \(sqlValue(row.pluginID)),
                \(quoted(row.kind)),
                \(quoted(row.payloadJSON)),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: row.expiresAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                payload_json = excluded.payload_json,
                expires_at = excluded.expires_at;
            """, on: handle)
        }
    }

    func deletePendingPluginWait(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("DELETE FROM pending_plugin_waits WHERE id = \(quoted(id));", on: handle)
        }
    }

    func upsertFactorySession(_ row: FactorySessionRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO factory_sessions (
                session_id, spec_json, stage, plugin_id, reviewer_calls, harness_runs, created_at, updated_at
            ) VALUES (
                \(quoted(row.sessionID)),
                \(sqlValue(row.specJSON)),
                \(quoted(row.stage)),
                \(sqlValue(row.pluginID)),
                \(row.reviewerCalls),
                \(row.harnessRuns),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: row.updatedAt)))
            )
            ON CONFLICT(session_id) DO UPDATE SET
                spec_json = excluded.spec_json,
                stage = excluded.stage,
                plugin_id = excluded.plugin_id,
                reviewer_calls = excluded.reviewer_calls,
                harness_runs = excluded.harness_runs,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func factorySession(sessionID: String) throws -> FactorySessionRow? {
        try withDatabaseHandle { handle in
            try allFactorySessionRows(
                from: """
                SELECT session_id, spec_json, stage, plugin_id, reviewer_calls, harness_runs, created_at, updated_at
                FROM factory_sessions
                WHERE session_id = \(quoted(sessionID))
                LIMIT 1;
                """,
                on: handle
            ).first
        }
    }

    private func allPluginRows(from sql: String, on handle: OpaquePointer) throws -> [PluginRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare plugins.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [PluginRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                PluginRow(
                    id: try columnString(statement, index: 0),
                    enabled: sqlite3_column_int(statement, 1) != 0,
                    currentVersionID: columnOptionalString(statement, index: 2),
                    createdAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 3)) ?? .now,
                    updatedAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 4)) ?? .now
                )
            )
        }
        return rows
    }

    private func allPluginVersionRows(from sql: String, on handle: OpaquePointer) throws -> [PluginVersionRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare plugin versions.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [PluginVersionRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                PluginVersionRow(
                    id: try columnString(statement, index: 0),
                    pluginID: try columnString(statement, index: 1),
                    version: try columnString(statement, index: 2),
                    contentHash: try columnString(statement, index: 3),
                    status: try columnString(statement, index: 4),
                    volumeName: columnOptionalString(statement, index: 5),
                    manifestJSON: try columnString(statement, index: 6),
                    runtimeJSON: columnOptionalString(statement, index: 7),
                    dependenciesJSON: try columnString(statement, index: 8),
                    createdAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 9)) ?? .now
                )
            )
        }
        return rows
    }

    private func allPluginGrantRows(from sql: String, on handle: OpaquePointer) throws -> [PluginGrantRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare plugin grants.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [PluginGrantRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                PluginGrantRow(
                    id: try columnString(statement, index: 0),
                    pluginID: try columnString(statement, index: 1),
                    versionID: try columnString(statement, index: 2),
                    authRefsJSON: try columnString(statement, index: 3),
                    attachHostsJSON: try columnString(statement, index: 4),
                    notifySessionID: columnOptionalString(statement, index: 5),
                    dependenciesJSON: try columnString(statement, index: 6),
                    createdAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 7)) ?? .now
                )
            )
        }
        return rows
    }

    private func allPluginInvokeRows(from sql: String, on handle: OpaquePointer) throws -> [PluginInvokeRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare plugin invokes.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [PluginInvokeRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                PluginInvokeRow(
                    id: try columnString(statement, index: 0),
                    pluginID: columnOptionalString(statement, index: 1),
                    versionID: columnOptionalString(statement, index: 2),
                    invokeID: try columnString(statement, index: 3),
                    kind: try columnString(statement, index: 4),
                    status: try columnString(statement, index: 5),
                    hop: Int(sqlite3_column_int(statement, 6)),
                    principalJSON: try columnString(statement, index: 7),
                    resultJSON: columnOptionalString(statement, index: 8),
                    errorMessage: columnOptionalString(statement, index: 9),
                    createdAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 10)) ?? .now,
                    updatedAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 11)) ?? .now
                )
            )
        }
        return rows
    }

    private func allFactorySessionRows(from sql: String, on handle: OpaquePointer) throws -> [FactorySessionRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare factory sessions.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [FactorySessionRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                FactorySessionRow(
                    sessionID: try columnString(statement, index: 0),
                    specJSON: columnOptionalString(statement, index: 1),
                    stage: try columnString(statement, index: 2),
                    pluginID: columnOptionalString(statement, index: 3),
                    reviewerCalls: Int(sqlite3_column_int(statement, 4)),
                    harnessRuns: Int(sqlite3_column_int(statement, 5)),
                    createdAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 6)) ?? .now,
                    updatedAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 7)) ?? .now
                )
            )
        }
        return rows
    }
}
