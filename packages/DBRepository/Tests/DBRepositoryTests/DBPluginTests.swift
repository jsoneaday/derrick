import XCTest
import Plugin
import ServiceContracts
@testable import DBRepository

final class DBPluginTests: XCTestCase {
    func testPluginGrantAndDeleteKeepsInvokes() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        try await repository.upsertPlugin(PluginRow(id: "daily-news", enabled: true))
        let version = PluginVersionRow(
            pluginID: "daily-news",
            version: "1.0.0",
            contentHash: String(repeating: "ab", count: 32),
            status: "promoted",
            manifestJSON: #"{"name":"daily-news"}"#
        )
        try await repository.upsertPluginVersion(version)
        try await repository.upsertPluginGrant(
            PluginGrantRow(
                pluginID: "daily-news",
                versionID: version.id,
                authRefsJSON: #"[{"name":"gmail","provider":"google"}]"#,
                attachHostsJSON: #"["gmail.googleapis.com"]"#,
                notifySessionID: "chat-1",
                dependenciesJSON: #"{}"#
            )
        )
        let principal = try JSONEncoder.service.encode(ServicePrincipal.plugin(pluginID: "daily-news", version: "1.0.0"))
        try await repository.upsertPluginInvoke(
            PluginInvokeRow(
                pluginID: "daily-news",
                versionID: version.id,
                invokeID: "inv-1",
                kind: "manual",
                status: "succeeded",
                principalJSON: String(data: principal, encoding: .utf8)!
            )
        )

        let plugins = try await repository.listPlugins()
        XCTAssertEqual(plugins.map(\.id), ["daily-news"])
        let grants = try await repository.listPluginGrants(pluginID: "daily-news")
        XCTAssertEqual(grants.count, 1)
        try await repository.deletePlugin(id: "daily-news")
        let remaining = try await repository.listPlugins()
        XCTAssertTrue(remaining.isEmpty)
        let versions = try await repository.listPluginVersions(pluginID: "daily-news")
        XCTAssertTrue(versions.isEmpty)
        let leftoverGrants = try await repository.listPluginGrants(pluginID: "daily-news")
        XCTAssertTrue(leftoverGrants.isEmpty)
        let invoke = try await repository.pluginInvoke(invokeID: "inv-1")
        XCTAssertNotNil(invoke)
        XCTAssertNil(invoke?.pluginID)
    }

    func testUninstallAllowsSameIdReinstallAndStopsJobs() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let version = PluginVersionRow(
            pluginID: "daily-news",
            version: "1.0.0",
            contentHash: String(repeating: "ab", count: 32),
            status: "promoted",
            volumeName: "derrick-plugin-data-daily-news",
            manifestJSON: #"{"name":"daily-news"}"#,
            entrypointSource: "export function handle() { return []; }"
        )
        try await repository.installPromotedPluginVersion(
            version,
            pluginID: "daily-news",
            grant: PluginGrantRow(pluginID: "daily-news", versionID: version.id)
        )
        try await repository.upsertFactorySession(
            FactorySessionRow(sessionID: "factory-1", specJSON: #"{"pluginID":"daily-news"}"#, stage: "promoted", pluginID: "daily-news", reviewerCalls: 2, harnessRuns: 1)
        )
        let factoryRows = try await repository.factorySessions(pluginID: "daily-news")
        XCTAssertEqual(factoryRows.map(\.sessionID), ["factory-1"])
        let tool = JobRunToolPayload(
            toolName: "plugin.invoke",
            argumentsJSON: #"{"plugin_id":"daily-news"}"#
        )
        let stepsJSON = String(
            data: try JSONEncoder.service.encode([try CreateJobStepSpec.runTool(tool)]),
            encoding: .utf8
        )!
        try await repository.insertSchedule(
            JobScheduleRow(
                id: "sched-1",
                name: "daily-news-job",
                enabled: true,
                principalJSON: "{}",
                source: "test",
                recurrenceKind: "interval",
                intervalSeconds: 3600,
                stepsJSON: stepsJSON,
                nextFireAt: .now,
                lastFiredAt: nil,
                createdAt: .now,
                updatedAt: .now
            )
        )
        try await repository.insertJob(
            JobRow(
                id: "job-1",
                status: JobStatus.pending.rawValue,
                principalJSON: "{}",
                source: "test",
                correlationID: nil,
                runAt: .now,
                createdAt: .now,
                updatedAt: .now,
                errorMessage: nil
            ),
            steps: [
                JobStepRow(
                    id: "step-1",
                    jobID: "job-1",
                    index: 0,
                    kind: JobStepKind.runTool.rawValue,
                    status: JobStepStatus.pending.rawValue,
                    payloadJSON: String(data: try JSONEncoder.service.encode(tool), encoding: .utf8)!
                )
            ]
        )

        let result = try await repository.uninstallPlugin(id: "daily-news")
        XCTAssertEqual(result.volumeNames, ["derrick-plugin-data-daily-news"])
        XCTAssertEqual(result.disabledScheduleIDs, ["sched-1"])
        XCTAssertEqual(result.cancelledJobIDs, ["job-1"])
        let gone = try await repository.plugin(id: "daily-news")
        XCTAssertNil(gone)
        let leftoverVersions = try await repository.listPluginVersions(pluginID: "daily-news")
        XCTAssertTrue(leftoverVersions.isEmpty)
        let leftoverGrantsAfter = try await repository.listPluginGrants(pluginID: "daily-news")
        XCTAssertTrue(leftoverGrantsAfter.isEmpty)
        let session = try await repository.factorySession(sessionID: "factory-1")
        XCTAssertNil(session?.pluginID)
        XCTAssertNil(session?.specJSON)
        XCTAssertEqual(session?.stage, "spec")
        XCTAssertEqual(session?.reviewerCalls, 0)
        let schedule = try await repository.fetchSchedule(id: "sched-1")
        XCTAssertEqual(schedule?.enabled, false)
        let job = try await repository.fetchJob(id: "job-1")?.0
        XCTAssertEqual(job?.status, JobStatus.cancelled.rawValue)

        let again = PluginVersionRow(
            pluginID: "daily-news",
            version: "1.0.0",
            contentHash: String(repeating: "ab", count: 32),
            status: "promoted",
            manifestJSON: #"{"name":"daily-news"}"#
        )
        try await repository.installPromotedPluginVersion(
            again,
            pluginID: "daily-news",
            grant: PluginGrantRow(pluginID: "daily-news", versionID: again.id)
        )
        let reinstalled = try await repository.plugin(id: "daily-news")
        XCTAssertEqual(reinstalled?.enabled, true)
    }

    func testBlacklistAndExceptionPersist() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let entry = try BlacklistEntry.parse("*.example.com")
        try await repository.addEgressBlacklistEntry(entry)
        try await repository.addEgressBlacklistException(try BlacklistEntry.parse("api.example.com"))

        let list = try await repository.listEgressBlacklist()
        XCTAssertEqual(list.map(\.displayPattern), ["*.example.com"])
        let exceptions = try await repository.listEgressBlacklistExceptions()
        XCTAssertEqual(exceptions.map(\.pattern), ["api.example.com"])
    }

    func testFirstPromoteInsertsPluginBeforeVersion() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let version = PluginVersionRow(
            pluginID: "daily-news-summary",
            version: "1.0.0",
            contentHash: String(repeating: "cd", count: 32),
            status: "promoted",
            manifestJSON: #"{"name":"daily-news-summary"}"#,
            entrypointSource: "export function handle() { return []; }"
        )
        try await repository.installPromotedPluginVersion(
            version,
            pluginID: "daily-news-summary",
            grant: PluginGrantRow(pluginID: "daily-news-summary", versionID: version.id)
        )

        let plugin = try await repository.plugin(id: "daily-news-summary")
        XCTAssertEqual(plugin?.enabled, true)
        XCTAssertEqual(plugin?.currentVersionID, version.id)
        let loaded = try await repository.pluginVersion(id: version.id)
        XCTAssertEqual(loaded?.pluginID, "daily-news-summary")
        let grants = try await repository.listPluginGrants(pluginID: "daily-news-summary")
        XCTAssertEqual(grants.count, 1)
    }

    func testVersionInsertWithoutPluginFailsForeignKey() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let version = PluginVersionRow(
            pluginID: "missing-parent",
            version: "1.0.0",
            contentHash: String(repeating: "ef", count: 32),
            status: "promoted",
            manifestJSON: #"{"name":"missing-parent"}"#
        )
        do {
            try await repository.upsertPluginVersion(version)
            XCTFail("expected FOREIGN KEY failure")
        } catch {
            let text = String(describing: error)
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains("foreign key"),
                "unexpected error: \(text)"
            )
        }
    }

    func testSecondPromoteKeepsOnePluginRowAndLatestVersion() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let first = PluginVersionRow(
            pluginID: "daily-news",
            version: "1.0.0",
            contentHash: String(repeating: "aa", count: 32),
            status: "promoted",
            manifestJSON: #"{"name":"daily-news","version":"1.0.0"}"#,
            entrypointSource: "v1"
        )
        try await repository.installPromotedPluginVersion(
            first,
            pluginID: "daily-news",
            grant: PluginGrantRow(pluginID: "daily-news", versionID: first.id)
        )
        let second = PluginVersionRow(
            pluginID: "daily-news",
            version: "1.0.1",
            contentHash: String(repeating: "bb", count: 32),
            status: "promoted",
            manifestJSON: #"{"name":"daily-news","version":"1.0.1"}"#,
            entrypointSource: "v2"
        )
        try await repository.installPromotedPluginVersion(
            second,
            pluginID: "daily-news",
            grant: PluginGrantRow(pluginID: "daily-news", versionID: second.id)
        )

        let plugins = try await repository.listPlugins()
        XCTAssertEqual(plugins.map(\.id), ["daily-news"])
        XCTAssertEqual(plugins.first?.currentVersionID, second.id)
        let versions = try await repository.listPluginVersions(pluginID: "daily-news")
        XCTAssertEqual(Set(versions.map(\.version)), ["1.0.0", "1.0.1"])
        let previous = try await repository.pluginVersion(id: first.id)
        XCTAssertEqual(previous?.status, "superseded")
        let current = try await repository.pluginVersion(id: second.id)
        XCTAssertEqual(current?.entrypointSource, "v2")

        _ = try await repository.deletePluginVersion(id: second.id)
        let afterDelete = try await repository.plugin(id: "daily-news")
        XCTAssertEqual(afterDelete?.currentVersionID, first.id)
        let leftover = try await repository.listPluginVersions(pluginID: "daily-news")
        XCTAssertEqual(leftover.map(\.id), [first.id])
        XCTAssertEqual(leftover.first?.status, "promoted")

        _ = try await repository.deletePluginVersion(id: first.id)
        let gone = try await repository.plugin(id: "daily-news")
        XCTAssertNil(gone)
    }

    func testFactorySessionUsageBuckets() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let sessionID = FactorySessionID.make()
        try await repository.upsertFactorySession(
            FactorySessionRow(sessionID: sessionID, stage: "review", reviewerCalls: 2, harnessRuns: 1)
        )
        let loaded = try await repository.factorySession(sessionID: sessionID)
        XCTAssertEqual(loaded?.reviewerCalls, 2)
        XCTAssertEqual(loaded?.harnessRuns, 1)
        XCTAssertTrue(FactorySessionID.isFactorySession(sessionID))
    }

    private func makeTestRepository() throws -> DBRepository {
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
}
