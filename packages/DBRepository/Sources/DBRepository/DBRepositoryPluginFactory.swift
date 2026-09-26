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
        let artifact = release.compiledArtifact.base64EncodedString()
        try withDatabaseHandle { handle in
            try Self.withImmediateTransaction(on: handle) {
                try Self.execute("""
                INSERT INTO plugin_factory_releases (
                    plugin_id, version, content_hash, manifest_json, runtime_json,
                    guest_source, artifact_base64, review_summary, created_at
                ) VALUES (
                    \(quoted(release.pluginID)),
                    \(quoted(release.version)),
                    \(quoted(release.contentHash.rawValue)),
                    \(quoted(release.manifestJSON)),
                    \(quoted(release.runtimeJSON)),
                    \(quoted(release.guestSource)),
                    \(quoted(artifact)),
                    \(quoted(release.reviewSummary)),
                    \(quoted(Self.iso8601Formatter().string(from: .now)))
                );
                """, on: handle)
                try self.insertSkillFiles(release, on: handle)
            }
        }
    }

    func pluginFactoryRelease(pluginID: String, version: String) throws -> PluginFactoryRelease? {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT plugin_id, version, content_hash, manifest_json, runtime_json,
                   guest_source, artifact_base64, review_summary
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
                let summaryC = sqlite3_column_text(statement, 7),
                let artifact = Data(base64Encoded: String(cString: artifactC)),
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
                skillFiles: try skillFiles(pluginID: pluginID, version: version, on: handle),
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

    func listLatestPluginFactoryManifests() throws -> [PluginFactoryManifestRecord] {
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
            var rows: [PluginFactoryManifestRecord] = []
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
                    PluginFactoryManifestRecord(
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
        _ = try purgePlugin(pluginID: pluginID, version: version)
    }

    /// Replaces an existing version in place after a manual package edit.
    /// The content hash must match the edited package files.
    func replacePluginFactoryRelease(_ release: PluginFactoryRelease) throws {
        guard release.verifyIntegrity() else {
            throw DBRepositoryError.sqliteOperationFailed("Refusing to store a release with an invalid content hash.")
        }
        // Version-only row replace — do not cascade associated plugin data.
        try withDatabaseHandle { handle in
            let pluginID = quoted(release.pluginID)
            let version = quoted(release.version)
            try Self.execute(
                "DELETE FROM plugin_skill_references WHERE plugin_id = \(pluginID) AND version = \(version);",
                on: handle
            )
            try Self.execute(
                "DELETE FROM plugin_skills WHERE plugin_id = \(pluginID) AND version = \(version);",
                on: handle
            )
            try Self.execute(
                "DELETE FROM plugin_factory_releases WHERE plugin_id = \(pluginID) AND version = \(version);",
                on: handle
            )
        }
        try savePluginFactoryRelease(release)
    }

    func listPluginSkillIndex() throws -> [PluginSkillDisclosure.IndexEntry] {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT s.plugin_id, s.path, s.skill_name, s.skill_description
            FROM plugin_skills s
            INNER JOIN plugin_factory_releases r
              ON r.plugin_id = s.plugin_id AND r.version = s.version
            INNER JOIN (
                SELECT plugin_id, MAX(created_at) AS created_at
                FROM plugin_factory_releases
                GROUP BY plugin_id
            ) latest
              ON latest.plugin_id = r.plugin_id AND latest.created_at = r.created_at
            ORDER BY s.plugin_id ASC, s.skill_name ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to list plugin skills.")
            }
            defer { sqlite3_finalize(statement) }
            var entries: [PluginSkillDisclosure.IndexEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let pluginIDC = sqlite3_column_text(statement, 0),
                    let pathC = sqlite3_column_text(statement, 1),
                    let nameC = sqlite3_column_text(statement, 2),
                    let descriptionC = sqlite3_column_text(statement, 3)
                else { continue }
                entries.append(
                    PluginSkillDisclosure.IndexEntry(
                        pluginID: String(cString: pluginIDC),
                        skillName: String(cString: nameC),
                        description: String(cString: descriptionC),
                        skillMarkdownPath: String(cString: pathC)
                    )
                )
            }
            return entries
        }
    }

    func pluginSkillBody(pluginID: String, version: String, skill: String) throws -> String? {
        let needle = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return try withDatabaseHandle { handle in
            let sql = """
            SELECT body FROM plugin_skills
            WHERE plugin_id = \(quoted(pluginID))
              AND version = \(quoted(version))
              AND (skill_name = \(quoted(needle)) OR path = \(quoted(needle)))
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to load a plugin skill.")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let bodyC = sqlite3_column_text(statement, 0) else {
                return nil
            }
            return String(cString: bodyC)
        }
    }

    func pluginSkillReference(
        pluginID: String,
        version: String,
        requested: String
    ) throws -> (path: String, body: String)? {
        let needle = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let filename = (needle as NSString).lastPathComponent
        return try withDatabaseHandle { handle in
            let sql = """
            SELECT path, body FROM plugin_skill_references
            WHERE plugin_id = \(quoted(pluginID))
              AND version = \(quoted(version))
              AND (
                path = \(quoted(needle))
                OR path LIKE \(quoted("%/references/\(filename)"))
              )
            ORDER BY CASE WHEN path = \(quoted(needle)) THEN 0 ELSE 1 END
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to load a plugin skill reference.")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let pathC = sqlite3_column_text(statement, 0),
                  let bodyC = sqlite3_column_text(statement, 1)
            else { return nil }
            return (String(cString: pathC), String(cString: bodyC))
        }
    }

    private func skillFiles(
        pluginID: String,
        version: String,
        on handle: OpaquePointer
    ) throws -> [String: String] {
        var files: [String: String] = [:]
        try appendSkillFiles(
            """
            SELECT path, body FROM plugin_skills
            WHERE plugin_id = \(quoted(pluginID)) AND version = \(quoted(version));
            """,
            into: &files,
            on: handle
        )
        try appendSkillFiles(
            """
            SELECT path, body FROM plugin_skill_references
            WHERE plugin_id = \(quoted(pluginID)) AND version = \(quoted(version));
            """,
            into: &files,
            on: handle
        )
        return files
    }

    private func appendSkillFiles(
        _ sql: String,
        into files: inout [String: String],
        on handle: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to load plugin skill files.")
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let pathC = sqlite3_column_text(statement, 0),
                let bodyC = sqlite3_column_text(statement, 1)
            else { continue }
            files[String(cString: pathC)] = String(cString: bodyC)
        }
    }

    private func insertSkillFiles(_ release: PluginFactoryRelease, on handle: OpaquePointer) throws {
        for (path, body) in release.skillFiles.sorted(by: { $0.key < $1.key }) {
            let catalog = PluginSkillDisclosure.catalogFields(path: path, body: body)
            if let name = catalog.name {
                let description = catalog.description ?? release.reviewSummary
                try Self.execute(
                    """
                    INSERT INTO plugin_skills (
                        plugin_id, version, path, skill_name, skill_description, body
                    ) VALUES (
                        \(quoted(release.pluginID)),
                        \(quoted(release.version)),
                        \(quoted(path)),
                        \(quoted(name)),
                        \(quoted(description)),
                        \(quoted(body))
                    );
                    """,
                    on: handle
                )
            } else if PluginFactorySkillFile.isSkillReferencePath(path) {
                try Self.execute(
                    """
                    INSERT INTO plugin_skill_references (
                        plugin_id, version, path, body
                    ) VALUES (
                        \(quoted(release.pluginID)),
                        \(quoted(release.version)),
                        \(quoted(path)),
                        \(quoted(body))
                    );
                    """,
                    on: handle
                )
            }
        }
    }
}

extension DBRepository: PluginFactoryManifestCatalog {}
