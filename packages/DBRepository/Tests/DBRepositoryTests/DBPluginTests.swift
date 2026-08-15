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
        let invoke = try await repository.pluginInvoke(invokeID: "inv-1")
        XCTAssertNotNil(invoke)
        XCTAssertNil(invoke?.pluginID)
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
