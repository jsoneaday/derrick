import XCTest
import SQLite3
import Plugin
@testable import DBRepository

final class DBRepositoryTests: XCTestCase {
    func testCreatesEmptySQLiteDatabaseFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        let url = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "derrick.sqlite3")
    }

    func testRejectsInvalidCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        do {
            _ = try await repository.createEmptyDatabaseIfNeeded(username: "wrong", password: "wrong")
            XCTFail("Expected authentication to fail")
        } catch DBRepositoryError.authenticationFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMigratesSchemaUpAndDown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        let url = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        XCTAssertEqual(try schemaVersion(at: url), DatabaseSchema.latestVersion)
        XCTAssertTrue(try tableExists(named: "memory_sessions", at: url))
        XCTAssertTrue(try tableExists(named: "memory_records", at: url))
        XCTAssertTrue(try tableExists(named: "egress_allowed_domain_suffixes", at: url))
        XCTAssertTrue(try tableExists(named: "content_sensitivity_grants", at: url))
        XCTAssertFalse(try tableExists(named: "plugins", at: url))
        XCTAssertFalse(try tableExists(named: "plugin_versions", at: url))
        XCTAssertFalse(try tableExists(named: "plugin_grants", at: url))
        XCTAssertFalse(try tableExists(named: "plugin_invokes", at: url))
        XCTAssertFalse(try tableExists(named: "pending_plugin_waits", at: url))
        XCTAssertTrue(try tableExists(named: "egress_blacklist", at: url))
        XCTAssertTrue(try tableExists(named: "egress_blacklist_exceptions", at: url))
        XCTAssertFalse(try tableExists(named: "factory_sessions", at: url))
        XCTAssertTrue(try tableExists(named: "policy_approvals", at: url))

        _ = try await repository.migrateSessionMemory(username: "app-user", password: "app-secret", to: 23)
        XCTAssertEqual(try schemaVersion(at: url), 23)
        XCTAssertTrue(try tableExists(named: "memory_sessions", at: url))
        XCTAssertFalse(try tableExists(named: "plugins", at: url))
    }

    func testRetiredFactoryMemoryIsPurgedByMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )
        let repository = DBRepository(configuration: configuration)
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        _ = try await repository.migrateSessionMemory(username: "app-user", password: "app-secret", to: 22)

        let record = makeRecord(
            sessionID: "factory-retired",
            createdAt: .now,
            prompt: "old factory instruction"
        )
        try await repository.upsert(record)
        let beforePurge = try await repository.records(
            sessionKey: MemorySessionKey(sessionID: "factory-retired", agentID: "ui")
        )
        XCTAssertEqual(beforePurge.count, 1)

        _ = try await repository.migrateSessionMemory(username: "app-user", password: "app-secret")
        let afterPurge = try await repository.records(
            sessionKey: MemorySessionKey(sessionID: "factory-retired", agentID: "ui")
        )
        XCTAssertTrue(afterPurge.isEmpty)
    }

    func testLegacyScriptRuntimeDataIsPurgedIdempotently() async throws {
        let repository = try makeRepository()
        let url = try await repository.createEmptyDatabaseIfNeeded(
            username: "app-user",
            password: "app-secret"
        )
        _ = try await repository.migrateSessionMemory(
            username: "app-user",
            password: "app-secret",
            to: 25
        )

        try await repository.upsert(
            makeRecord(
                sessionID: "legacy-script",
                createdAt: .now,
                prompt: #"{"tool":"script_exec","script":"function handle() {} // script.js"}"#
            )
        )
        try await repository.upsert(
            makeRecord(
                sessionID: "swift-script",
                createdAt: .now,
                prompt: #"{"tool":"script_exec","script":"let data = readLine()"}"#
            )
        )

        _ = try await repository.migrateSessionMemory(
            username: "app-user",
            password: "app-secret"
        )
        let legacyRecords = try await repository.records(
            sessionKey: MemorySessionKey(sessionID: "legacy-script", agentID: "ui")
        )
        let swiftRecords = try await repository.records(
            sessionKey: MemorySessionKey(sessionID: "swift-script", agentID: "ui")
        )
        XCTAssertTrue(legacyRecords.isEmpty)
        XCTAssertEqual(swiftRecords.count, 1)
        _ = try await repository.migrateSessionMemory(
            username: "app-user",
            password: "app-secret"
        )
        XCTAssertEqual(try schemaVersion(at: url), DatabaseSchema.latestVersion)
    }

    func testApprovedPluginFactoryReleasePersistsAndVerifies() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        let artifact = Data("compiled".utf8)
        let skillFiles = ["skills/weather/SKILL.md": "# Weather"]
        let files: [String: Data] = [
            "plugin.json": Data(#"{"name":"weather-tool"}"#.utf8),
            "app.derrick/runtime.json": Data(#"{"language":"swift"}"#.utf8),
            "app.derrick/plugin.swift": Data("print(\"[]\")".utf8),
            "app.derrick/plugin": artifact,
            "skills/weather/SKILL.md": Data("# Weather".utf8),
        ]
        let release = PluginFactoryRelease(
            pluginID: "weather-tool",
            version: "1.0.0",
            manifestJSON: String(decoding: files["plugin.json"] ?? Data(), as: UTF8.self),
            runtimeJSON: String(decoding: files["app.derrick/runtime.json"] ?? Data(), as: UTF8.self),
            swiftSource: "print(\"[]\")",
            compiledArtifact: artifact,
            skillFiles: skillFiles,
            contentHash: PluginContentHash.hash(files: files),
            reviewSummary: "approved"
        )

        try await repository.savePluginFactoryRelease(release)
        let loaded = try await repository.pluginFactoryRelease(
            pluginID: "weather-tool",
            version: "1.0.0"
        )
        XCTAssertEqual(loaded?.contentHash, release.contentHash)
        XCTAssertEqual(loaded?.skillFiles, skillFiles)
        XCTAssertTrue(loaded?.verifyIntegrity() == true)
    }

    func testContentSensitivityGrantCRUD() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )
        let repository = DBRepository(configuration: configuration)
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        try await repository.saveContentSensitivityGrant(
            ContentSensitivityGrant(category: "email", scope: "permanent", actor: "tester")
        )
        var permanent = try await repository.loadContentSensitivityGrants(permanentOnly: true)
        XCTAssertEqual(permanent.map(\.category), ["email"])

        try await repository.saveContentSensitivityGrant(
            ContentSensitivityGrant(category: "email", scope: "permanent", actor: "tester2")
        )
        permanent = try await repository.loadContentSensitivityGrants(permanentOnly: true)
        XCTAssertEqual(permanent.count, 1)
        XCTAssertEqual(permanent.first?.actor, "tester2")

        try await repository.saveContentSensitivityGrant(
            ContentSensitivityGrant(category: "phone", scope: "session", sessionID: "s1", actor: "u")
        )
        let forSession = try await repository.loadContentSensitivityGrants(sessionID: "s1")
        XCTAssertEqual(Set(forSession.map(\.category)), Set(["email", "phone"]))

        try await repository.deletePermanentContentSensitivityGrant(category: "email")
        permanent = try await repository.loadContentSensitivityGrants(permanentOnly: true)
        XCTAssertTrue(permanent.isEmpty)
    }

    func testEgressAllowlistSeedAndCRUD() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let inserted = try await repository.seedEgressAllowedDomainSuffixesIfNeeded(
            ["github.com", "pypi.org"],
            source: "seed"
        )
        XCTAssertEqual(inserted, 2)
        let again = try await repository.seedEgressAllowedDomainSuffixesIfNeeded(
            ["github.com", "pypi.org"],
            source: "seed"
        )
        XCTAssertEqual(again, 0)

        try await repository.saveEgressAllowedDomainSuffix(
            EgressAllowedDomainSuffix(suffix: "reactjs.org", source: "user")
        )
        let rows = try await repository.loadEgressAllowedDomainSuffixes()
        XCTAssertTrue(rows.map(\.suffix).contains("reactjs.org"))
        XCTAssertTrue(rows.map(\.suffix).contains("github.com"))

        try await repository.deleteEgressAllowedDomainSuffix(suffix: "reactjs.org")
        let after = try await repository.loadEgressAllowedDomainSuffixes()
        XCTAssertFalse(after.map(\.suffix).contains("reactjs.org"))
    }

    func testSearchPriorReturnsNewestMatchingPastSessionsOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        try await repository.upsert(makeRecord(sessionID: "older", createdAt: Calendar.current.date(byAdding: .day, value: -2, to: Date())!, prompt: "older prompt"))
        try await repository.upsert(makeRecord(sessionID: "newer", createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!, prompt: "newer prompt"))
        try await repository.upsert(makeRecord(sessionID: "current", createdAt: Date(), prompt: "current prompt"))

        let results = try await repository.searchPrior(
            sessionKey: MemorySessionKey(sessionID: "current", agentID: "ui"),
            query: nil,
            limit: 1,
            page: 1
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.pair.prompt, "newer prompt")

        let queryResults = try await repository.searchPrior(
            sessionKey: MemorySessionKey(sessionID: "current", agentID: "ui"),
            query: "older",
            limit: 10,
            page: 1
        )

        XCTAssertEqual(queryResults.map(\.pair.prompt), ["older prompt"])
    }

    func testSearchPriorExcludesArchivedOlderThanSixMonthsUnlessRequested() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let archivedDate = Calendar.current.date(byAdding: .month, value: -7, to: Date())!
        try await repository.upsert(makeRecord(sessionID: "archived", createdAt: archivedDate, prompt: "archived prompt"))
        try await repository.upsert(makeRecord(sessionID: "current", createdAt: Date(), prompt: "current prompt"))

        let defaultResults = try await repository.searchPrior(
            sessionKey: MemorySessionKey(sessionID: "current", agentID: "ui"),
            query: nil,
            limit: 10,
            page: 1
        )
        XCTAssertTrue(defaultResults.isEmpty)

        let archivedResults = try await repository.searchPrior(
            sessionKey: MemorySessionKey(sessionID: "current", agentID: "ui"),
            query: nil,
            limit: 10,
            page: 1,
            includeArchived: true
        )
        XCTAssertEqual(archivedResults.map(\.pair.prompt), ["archived prompt"])
    }

    func testSearchPriorClampsLimitToMaxRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        for index in 0..<150 {
            try await repository.upsert(
                makeRecord(
                    sessionID: "past-\(index)",
                    createdAt: Calendar.current.date(byAdding: .minute, value: -index, to: Date())!,
                    prompt: "prompt \(index)"
                )
            )
        }

        let results = try await repository.searchPrior(
            sessionKey: MemorySessionKey(sessionID: "current", agentID: "ui"),
            query: nil,
            limit: 500,
            page: 1
        )
        XCTAssertEqual(results.count, MemoryQueryPolicy.maxRowsPerRequest)
    }

    private func schemaVersion(at url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "DBRepositoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite database at \(url.path)"])
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "DBRepositoryTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to prepare schema version query"])
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "DBRepositoryTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to read schema version"])
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    private func tableExists(named tableName: String, at url: URL) throws -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "DBRepositoryTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite database at \(url.path)"])
        }
        defer { sqlite3_close(handle) }

        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(tableName)' LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "DBRepositoryTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unable to prepare table existence query"])
        }
        defer { sqlite3_finalize(statement) }

        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func makeRecord(sessionID: String, createdAt: Date, prompt: String) -> MemoryRecord {
        let pair = PromptResponsePair(
            sessionID: sessionID,
            agentID: "ui",
            prompt: prompt,
            completion: "completion",
            createdAt: createdAt
        )
        return MemoryRecord(id: pair.id, pair: pair)
    }

    private func makeRepository() throws -> DBRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: "ui",
                databaseName: "derrick",
                databaseDirectoryURL: directory,
                username: "app-user",
                password: "app-secret"
            )
        )
    }

    func testEnablesWALAndSurvivesConcurrentWriters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let primary = DBRepository(configuration: configuration)
        let url = try await primary.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        XCTAssertEqual(try journalMode(at: url).uppercased(), "WAL")

        // Two independent repository instances (simulates UI + AgentService).
        let uiRepo = DBRepository(configuration: configuration)
        let agentRepo = DBRepository(configuration: configuration)

        let records: [MemoryRecord] = (0..<20).map { i in
            makeRecord(
                sessionID: "s-\(i)",
                createdAt: Date().addingTimeInterval(-Double(i)),
                prompt: "prompt \(i)"
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, record) in records.enumerated() {
                group.addTask {
                    let repo = i.isMultiple(of: 2) ? uiRepo : agentRepo
                    try await repo.upsert(record)
                }
            }
            try await group.waitForAll()
        }

        let rows = try await uiRepo.records(sessionKey: MemorySessionKey(sessionID: "s-0", agentID: "ui"))
        XCTAssertEqual(rows.count, 1)
    }

    private func journalMode(at url: URL) throws -> String {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "DBRepositoryTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite database"])
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA journal_mode;", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "DBRepositoryTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Unable to prepare journal_mode"])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let c = sqlite3_column_text(statement, 0) else {
            throw NSError(domain: "DBRepositoryTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unable to read journal_mode"])
        }
        return String(cString: c)
    }
}
