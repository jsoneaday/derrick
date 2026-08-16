import Foundation
import SQLite3
import Plugin
import ServiceContracts

public struct PluginRow: Sendable, Hashable {
    public var id: String
    public var enabled: Bool
    public var currentVersionID: String?
    public var isSystem: Bool
    public var hooksJSON: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        enabled: Bool = true,
        currentVersionID: String? = nil,
        isSystem: Bool = false,
        hooksJSON: String = "[]",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.enabled = enabled
        self.currentVersionID = currentVersionID
        self.isSystem = isSystem
        self.hooksJSON = hooksJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var hookGrants: [PluginHookGrant] {
        PluginHookGrant.decodeList(hooksJSON)
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
    public var entrypointSource: String
    public var skillsJSON: String
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
        entrypointSource: String = "",
        skillsJSON: String = "{}",
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
        self.entrypointSource = entrypointSource
        self.skillsJSON = skillsJSON
        self.createdAt = createdAt
    }

    public var skills: [String: String] {
        guard let data = skillsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    public var hasHandle: Bool {
        !entrypointSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    public var instructionPluginID: String?
    public var reviewerCalls: Int
    public var harnessRuns: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        sessionID: String,
        specJSON: String? = nil,
        stage: String,
        pluginID: String? = nil,
        instructionPluginID: String? = nil,
        reviewerCalls: Int = 0,
        harnessRuns: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.sessionID = sessionID
        self.specJSON = specJSON
        self.stage = stage
        self.pluginID = pluginID
        self.instructionPluginID = instructionPluginID
        self.reviewerCalls = reviewerCalls
        self.harnessRuns = harnessRuns
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PluginUninstallResult: Sendable, Hashable {
    public var pluginID: String
    public var volumeNames: [String]
    public var disabledScheduleIDs: [String]
    public var cancelledJobIDs: [String]

    public init(
        pluginID: String,
        volumeNames: [String] = [],
        disabledScheduleIDs: [String] = [],
        cancelledJobIDs: [String] = []
    ) {
        self.pluginID = pluginID
        self.volumeNames = volumeNames
        self.disabledScheduleIDs = disabledScheduleIDs
        self.cancelledJobIDs = cancelledJobIDs
    }
}

public extension DBRepository {
    func upsertPlugin(_ row: PluginRow) throws {
        _ = try PluginID(row.id)
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO plugins (id, enabled, current_version_id, is_system, hooks_json, created_at, updated_at)
            VALUES (
                \(quoted(row.id)),
                \(row.enabled ? 1 : 0),
                \(sqlValue(row.currentVersionID)),
                \(row.isSystem ? 1 : 0),
                \(quoted(row.hooksJSON)),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: row.updatedAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                enabled = excluded.enabled,
                current_version_id = excluded.current_version_id,
                is_system = excluded.is_system,
                hooks_json = excluded.hooks_json,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func plugin(id: String) throws -> PluginRow? {
        try listPlugins(includeDisabled: true).first { $0.id == id }
    }

    func pluginVersion(id: String) throws -> PluginVersionRow? {
        try withDatabaseHandle { handle in
            try allPluginVersionRows(
                from: """
                SELECT id, plugin_id, version, content_hash, status, volume_name,
                       manifest_json, runtime_json, dependencies_json, created_at, entrypoint_source, skills_json
                FROM plugin_versions
                WHERE id = \(quoted(id))
                LIMIT 1;
                """,
                on: handle
            ).first
        }
    }

    func listPlugins(includeDisabled: Bool = true) throws -> [PluginRow] {
        try withDatabaseHandle { handle in
            let filter = includeDisabled ? "" : "WHERE enabled = 1"
            return try allPluginRows(
                from: "SELECT id, enabled, current_version_id, created_at, updated_at, is_system, hooks_json FROM plugins \(filter) ORDER BY id ASC;",
                on: handle
            )
        }
    }

    /// Host-defined plugins that every database must have.
    func seedSystemPlugins() throws {
        try seedCreatePlugin()
    }

    private func requireUserPlugin(id: String) throws {
        if let existing = try plugin(id: id), existing.isSystem {
            throw PluginManifestError.systemPluginLocked(id)
        }
    }

    private func seedCreatePlugin() throws {
        let desiredHash = CreatePluginSample.contentHash().rawValue
        let desiredHooks = CreatePluginSample.hooksJSON
        if let existing = try plugin(id: CreatePluginSample.pluginID),
           existing.isSystem,
           existing.enabled,
           let versionID = existing.currentVersionID,
           let version = try pluginVersion(id: versionID),
           version.contentHash == desiredHash {
            if existing.hooksJSON != desiredHooks {
                var updated = existing
                updated.hooksJSON = desiredHooks
                updated.updatedAt = .now
                try upsertPlugin(updated)
            }
            return
        }
        let version = PluginVersionRow(
            pluginID: CreatePluginSample.pluginID,
            version: CreatePluginSample.version,
            contentHash: desiredHash,
            status: "promoted",
            manifestJSON: CreatePluginSample.manifestJSON,
            runtimeJSON: CreatePluginSample.runtimeJSON,
            entrypointSource: "",
            skillsJSON: CreatePluginSample.skillsJSON
        )
        try upsertPlugin(
            PluginRow(
                id: CreatePluginSample.pluginID,
                enabled: true,
                currentVersionID: try plugin(id: CreatePluginSample.pluginID)?.currentVersionID,
                isSystem: true,
                hooksJSON: CreatePluginSample.hooksJSON
            )
        )
        try installPromotedPluginVersion(
            version,
            pluginID: CreatePluginSample.pluginID,
            grant: PluginGrantRow(pluginID: CreatePluginSample.pluginID, versionID: version.id)
        )
    }

    func setPluginEnabled(id: String, enabled: Bool, updatedAt: Date = .now) throws {
        try requireUserPlugin(id: id)
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE plugins
            SET enabled = \(enabled ? 1 : 0),
                updated_at = \(quoted(Self.iso8601Formatter().string(from: updatedAt)))
            WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    /// Removes the install so the same id can be promoted again.
    /// Versions and grants cascade. Invoke history is kept (`plugin_id` SET NULL).
    /// Pending waits, factory pointers, schedules, and queued jobs for this plugin are cleared.
    @discardableResult
    func deletePlugin(id: String) throws -> PluginUninstallResult {
        try uninstallPlugin(id: id)
    }

    @discardableResult
    func uninstallPlugin(id: String) throws -> PluginUninstallResult {
        let pluginID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pluginID.isEmpty else {
            return PluginUninstallResult(pluginID: id)
        }
        try requireUserPlugin(id: pluginID)
        let versions = try listPluginVersions(pluginID: pluginID)
        let volumeNames = versions.compactMap(\.volumeName).filter { !$0.isEmpty }
        let disabledSchedules = try disableSchedules(invokingPlugin: pluginID)
        let cancelledJobs = try cancelJobs(invokingPlugin: pluginID)

        try withDatabaseHandle { handle in
            try Self.execute("BEGIN IMMEDIATE;", on: handle)
            do {
                try Self.execute(
                    "UPDATE plugins SET current_version_id = NULL WHERE id = \(quoted(pluginID));",
                    on: handle
                )
                try Self.execute(
                    "DELETE FROM pending_plugin_waits WHERE plugin_id = \(quoted(pluginID));",
                    on: handle
                )
                try Self.execute("DELETE FROM plugins WHERE id = \(quoted(pluginID));", on: handle)
                try Self.execute(
                    """
                    UPDATE factory_sessions
                    SET plugin_id = NULL,
                        spec_json = NULL,
                        stage = 'spec',
                        reviewer_calls = 0,
                        harness_runs = 0,
                        updated_at = \(quoted(Self.iso8601Formatter().string(from: Date())))
                    WHERE plugin_id = \(quoted(pluginID));
                    """,
                    on: handle
                )
                try Self.execute("COMMIT;", on: handle)
            } catch {
                _ = try? Self.execute("ROLLBACK;", on: handle)
                throw error
            }
        }

        return PluginUninstallResult(
            pluginID: pluginID,
            volumeNames: volumeNames,
            disabledScheduleIDs: disabledSchedules,
            cancelledJobIDs: cancelledJobs
        )
    }

    /// Removes one version. Last version uninstalls the plugin.
    @discardableResult
    func deletePluginVersion(id versionID: String) throws -> PluginUninstallResult {
        guard let version = try pluginVersion(id: versionID) else {
            return PluginUninstallResult(pluginID: "")
        }
        try requireUserPlugin(id: version.pluginID)
        let siblings = try listPluginVersions(pluginID: version.pluginID)
        if siblings.count <= 1 {
            return try uninstallPlugin(id: version.pluginID)
        }
        let remaining = siblings.filter { $0.id != versionID }
        let nextCurrent = remaining.first
        try withDatabaseHandle { handle in
            try Self.execute("BEGIN IMMEDIATE;", on: handle)
            do {
                if let next = nextCurrent {
                    try Self.execute(
                        """
                        UPDATE plugins
                        SET current_version_id = \(quoted(next.id)),
                            updated_at = \(quoted(Self.iso8601Formatter().string(from: Date())))
                        WHERE id = \(quoted(version.pluginID));
                        """,
                        on: handle
                    )
                    try Self.execute(
                        "UPDATE plugin_versions SET status = 'promoted' WHERE id = \(quoted(next.id));",
                        on: handle
                    )
                } else {
                    try Self.execute(
                        "UPDATE plugins SET current_version_id = NULL WHERE id = \(quoted(version.pluginID));",
                        on: handle
                    )
                }
                try Self.execute(
                    "DELETE FROM plugin_versions WHERE id = \(quoted(versionID));",
                    on: handle
                )
                try Self.execute("COMMIT;", on: handle)
            } catch {
                _ = try? Self.execute("ROLLBACK;", on: handle)
                throw error
            }
        }
        return PluginUninstallResult(
            pluginID: version.pluginID,
            volumeNames: [version.volumeName].compactMap { $0 }.filter { !$0.isEmpty }
        )
    }

    private func disableSchedules(invokingPlugin pluginID: String) throws -> [String] {
        let schedules = try listSchedules(enabledOnly: false, limit: 500)
        var disabled: [String] = []
        for schedule in schedules where schedule.enabled {
            guard Self.jobStepsInvoke(pluginID: pluginID, stepsJSON: schedule.stepsJSON) else { continue }
            var updated = schedule
            updated.enabled = false
            updated.updatedAt = .now
            try updateSchedule(updated)
            disabled.append(schedule.id)
        }
        return disabled
    }

    private func cancelJobs(invokingPlugin pluginID: String) throws -> [String] {
        var cancelled: [String] = []
        for status in [JobStatus.pending.rawValue, JobStatus.scheduled.rawValue] {
            let jobs = try listJobs(status: status, limit: 500)
            for (job, steps) in jobs {
                let hits = steps.contains { Self.jobPayloadInvokes(pluginID: pluginID, payloadJSON: $0.payloadJSON) }
                guard hits else { continue }
                try updateJobStatus(
                    id: job.id,
                    status: JobStatus.cancelled.rawValue,
                    errorMessage: "Plugin \(pluginID) was deleted.",
                    errorCode: "plugin_deleted"
                )
                cancelled.append(job.id)
            }
        }
        return cancelled
    }

    private static func jobStepsInvoke(pluginID: String, stepsJSON: String) -> Bool {
        guard let data = stepsJSON.data(using: .utf8),
              let steps = try? JSONDecoder.service.decode([CreateJobStepSpec].self, from: data) else {
            return false
        }
        return steps.contains { jobPayloadInvokes(pluginID: pluginID, payloadJSON: $0.payloadJSON) }
    }

    private static func jobPayloadInvokes(pluginID: String, payloadJSON: String) -> Bool {
        let data = Data(payloadJSON.utf8)
        if let tool = try? JSONDecoder.service.decode(JobRunToolPayload.self, from: data) {
            return toolInvokes(pluginID: pluginID, tool: tool)
        }
        if let batch = try? JSONDecoder.service.decode(JobRunToolBatchPayload.self, from: data) {
            return batch.invocations.contains { toolInvokes(pluginID: pluginID, tool: $0) }
        }
        if let paired = try? JSONDecoder.service.decode(JobRunToolThenWakePayload.self, from: data) {
            return toolInvokes(pluginID: pluginID, tool: paired.tool)
        }
        return false
    }

    private static func toolInvokes(pluginID: String, tool: JobRunToolPayload) -> Bool {
        guard tool.toolName == "plugin.invoke",
              let data = tool.argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["plugin_id"] as? String else {
            return false
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == pluginID
    }

    func upsertPluginVersion(_ row: PluginVersionRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO plugin_versions (
                id, plugin_id, version, content_hash, status, volume_name,
                manifest_json, runtime_json, dependencies_json, entrypoint_source, skills_json, created_at
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
                \(quoted(row.entrypointSource)),
                \(quoted(row.skillsJSON)),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                status = excluded.status,
                volume_name = excluded.volume_name,
                manifest_json = excluded.manifest_json,
                runtime_json = excluded.runtime_json,
                dependencies_json = excluded.dependencies_json,
                entrypoint_source = excluded.entrypoint_source,
                skills_json = excluded.skills_json;
            """, on: handle)
        }
    }

    func listPluginVersions(pluginID: String) throws -> [PluginVersionRow] {
        try withDatabaseHandle { handle in
            try allPluginVersionRows(
                from: """
                SELECT id, plugin_id, version, content_hash, status, volume_name,
                       manifest_json, runtime_json, dependencies_json, created_at, entrypoint_source, skills_json
                FROM plugin_versions
                WHERE plugin_id = \(quoted(pluginID))
                ORDER BY created_at DESC;
                """,
                on: handle
            )
        }
    }

    /// First-time install: insert `plugins` (parent), then `plugin_versions`, then point
    /// `current_version_id`, then grant. Reversing that order fails the version FK.
    func installPromotedPluginVersion(
        _ version: PluginVersionRow,
        pluginID: String,
        grant: PluginGrantRow
    ) throws {
        if try plugin(id: pluginID) == nil {
            try upsertPlugin(PluginRow(id: pluginID, enabled: true, currentVersionID: nil))
        }
        if let existing = try plugin(id: pluginID),
           let previousID = existing.currentVersionID,
           previousID != version.id,
           var previous = try pluginVersion(id: previousID) {
            previous.status = "superseded"
            try upsertPluginVersion(previous)
        }
        try upsertPluginVersion(version)
        var plugin = try plugin(id: pluginID) ?? PluginRow(id: pluginID, enabled: true)
        plugin.enabled = true
        plugin.currentVersionID = version.id
        plugin.updatedAt = .now
        try upsertPlugin(plugin)
        try upsertPluginGrant(grant)
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
                session_id, spec_json, stage, plugin_id, instruction_plugin_id,
                reviewer_calls, harness_runs, created_at, updated_at
            ) VALUES (
                \(quoted(row.sessionID)),
                \(sqlValue(row.specJSON)),
                \(quoted(row.stage)),
                \(sqlValue(row.pluginID)),
                \(sqlValue(row.instructionPluginID)),
                \(row.reviewerCalls),
                \(row.harnessRuns),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: row.updatedAt)))
            )
            ON CONFLICT(session_id) DO UPDATE SET
                spec_json = excluded.spec_json,
                stage = excluded.stage,
                plugin_id = excluded.plugin_id,
                instruction_plugin_id = excluded.instruction_plugin_id,
                reviewer_calls = excluded.reviewer_calls,
                harness_runs = excluded.harness_runs,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func factorySessions(pluginID: String) throws -> [FactorySessionRow] {
        let pluginID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pluginID.isEmpty else { return [] }
        return try withDatabaseHandle { handle in
            try allFactorySessionRows(
                from: """
                SELECT session_id, spec_json, stage, plugin_id, reviewer_calls, harness_runs, created_at, updated_at, instruction_plugin_id
                FROM factory_sessions
                WHERE plugin_id = \(quoted(pluginID));
                """,
                on: handle
            )
        }
    }

    func listFactorySessions() throws -> [FactorySessionRow] {
        try withDatabaseHandle { handle in
            try allFactorySessionRows(
                from: """
                SELECT session_id, spec_json, stage, plugin_id, reviewer_calls, harness_runs, created_at, updated_at, instruction_plugin_id
                FROM factory_sessions
                ORDER BY updated_at DESC;
                """,
                on: handle
            )
        }
    }

    func factorySession(sessionID: String) throws -> FactorySessionRow? {
        try withDatabaseHandle { handle in
            try allFactorySessionRows(
                from: """
                SELECT session_id, spec_json, stage, plugin_id, reviewer_calls, harness_runs, created_at, updated_at, instruction_plugin_id
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
                    isSystem: sqlite3_column_int(statement, 5) != 0,
                    hooksJSON: columnOptionalString(statement, index: 6) ?? "[]",
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
                    entrypointSource: columnOptionalString(statement, index: 10) ?? "",
                    skillsJSON: columnOptionalString(statement, index: 11) ?? "{}",
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
                    instructionPluginID: columnOptionalString(statement, index: 8),
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
