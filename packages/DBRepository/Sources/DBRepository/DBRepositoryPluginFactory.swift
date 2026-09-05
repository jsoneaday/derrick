import Foundation
import Plugin
import SQLite3
import Structure

public extension DBRepository {
    /// Persists an approved release exactly once. Repeating the same release is
    /// idempotent; a changed package must use a new version.
    func savePluginFactoryRelease(_ release: PluginFactoryRelease) throws {
        guard release.verifyIntegrity() else {
            throw DBRepositoryError.sqliteOperationFailed("Refusing to store a release with an invalid content hash.")
        }
        if let existing = try pluginFactoryRelease(
            pluginID: release.pluginID,
            version: release.version
        ) {
            guard existing.contentHash == release.contentHash else {
                throw DBRepositoryError.sqliteOperationFailed(
                    "Plugin \(release.pluginID) version \(release.version) already exists with different content."
                )
            }
            return
        }
        let skillsData = try JSONEncoder().encode(release.skillFiles)
        let skillsJSON = String(decoding: skillsData, as: UTF8.self)
        let artifact = release.compiledArtifact.base64EncodedString()
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO plugin_factory_releases (
                plugin_id, version, content_hash, manifest_json, runtime_json,
                swift_source, artifact_base64, skill_files_json, review_summary, created_at
            ) VALUES (
                \(quoted(release.pluginID)),
                \(quoted(release.version)),
                \(quoted(release.contentHash.rawValue)),
                \(quoted(release.manifestJSON)),
                \(quoted(release.runtimeJSON)),
                \(quoted(release.guestSource)),
                \(quoted(artifact)),
                \(quoted(skillsJSON)),
                \(quoted(release.reviewSummary)),
                \(quoted(Self.iso8601Formatter().string(from: .now)))
            );
            """, on: handle)
        }
    }

    func pluginFactoryRelease(pluginID: String, version: String) throws -> PluginFactoryRelease? {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT plugin_id, version, content_hash, manifest_json, runtime_json,
                   swift_source, artifact_base64, skill_files_json, review_summary
            FROM plugin_factory_releases
            WHERE plugin_id = \(quoted(pluginID))
              AND version = \(quoted(version))
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare plugin factory release.")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard
                let id = sqlite3_column_text(statement, 0),
                let versionC = sqlite3_column_text(statement, 1),
                let hashC = sqlite3_column_text(statement, 2),
                let manifestC = sqlite3_column_text(statement, 3),
                let runtimeC = sqlite3_column_text(statement, 4),
                let sourceC = sqlite3_column_text(statement, 5),
                let artifactC = sqlite3_column_text(statement, 6),
                let skillsC = sqlite3_column_text(statement, 7),
                let summaryC = sqlite3_column_text(statement, 8),
                let artifact = Data(base64Encoded: String(cString: artifactC)),
                let skillsData = String(cString: skillsC).data(using: .utf8),
                let skillFiles = try? JSONDecoder().decode([String: String].self, from: skillsData),
                let contentHash = try? PluginContentHash(hex: String(cString: hashC))
            else {
                throw DBRepositoryError.sqliteOperationFailed("Stored plugin factory release is corrupt.")
            }
            let release = PluginFactoryRelease(
                pluginID: String(cString: id),
                version: String(cString: versionC),
                manifestJSON: String(cString: manifestC),
                runtimeJSON: String(cString: runtimeC),
                guestSource: String(cString: sourceC),
                compiledArtifact: artifact,
                skillFiles: skillFiles,
                contentHash: contentHash,
                reviewSummary: String(cString: summaryC)
            )
            guard release.verifyIntegrity() else {
                throw DBRepositoryError.sqliteOperationFailed("Stored plugin factory release failed integrity verification.")
            }
            return release
        }
    }

    func listPluginFactoryReleaseSummaries() throws -> [PluginFactoryReleaseSummary] {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT plugin_id, version, content_hash, review_summary
            FROM plugin_factory_releases
            ORDER BY plugin_id ASC, created_at DESC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare plugin factory release list.")
            }
            defer { sqlite3_finalize(statement) }
            var summaries: [PluginFactoryReleaseSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let id = sqlite3_column_text(statement, 0),
                    let version = sqlite3_column_text(statement, 1),
                    let hash = sqlite3_column_text(statement, 2),
                    let review = sqlite3_column_text(statement, 3)
                else {
                    continue
                }
                summaries.append(
                    PluginFactoryReleaseSummary(
                        pluginID: String(cString: id),
                        version: String(cString: version),
                        contentHash: String(cString: hash),
                        reviewSummary: String(cString: review)
                    )
                )
            }
            return summaries
        }
    }

    func listLatestPluginFactoryManifests() throws -> [(pluginID: String, version: String, manifestJSON: String, reviewSummary: String)] {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT plugin_id, version, manifest_json, review_summary
            FROM plugin_factory_releases r
            WHERE created_at = (
                SELECT MAX(created_at)
                FROM plugin_factory_releases r2
                WHERE r2.plugin_id = r.plugin_id
            )
            ORDER BY plugin_id ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare latest plugin factory manifests.")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [(pluginID: String, version: String, manifestJSON: String, reviewSummary: String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let id = sqlite3_column_text(statement, 0),
                    let version = sqlite3_column_text(statement, 1),
                    let manifest = sqlite3_column_text(statement, 2),
                    let review = sqlite3_column_text(statement, 3)
                else {
                    continue
                }
                rows.append(
                    (
                        pluginID: String(cString: id),
                        version: String(cString: version),
                        manifestJSON: String(cString: manifest),
                        reviewSummary: String(cString: review)
                    )
                )
            }
            return rows
        }
    }

    func deletePluginFactoryRelease(pluginID: String, version: String? = nil) throws {
        let versionClause = version.map {
            " AND version = \(quoted($0))"
        } ?? ""
        try withDatabaseHandle { handle in
            try Self.execute(
                """
                DELETE FROM plugin_factory_releases
                WHERE plugin_id = \(quoted(pluginID))\(versionClause);
                """,
                on: handle
            )
        }
    }
}
