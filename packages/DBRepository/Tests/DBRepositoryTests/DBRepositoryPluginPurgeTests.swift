import XCTest
import Plugin
@testable import DBRepository
import Structure

final class DBRepositoryPluginPurgeTests: XCTestCase {
    func testPurgePluginRemovesMessagingChatWorkflowAndHandledInOneShot() async throws {
        let repository = try await makeRepository()
        let release = makeGoFactoryRelease(pluginID: "slack-connector-9")
        try await repository.savePluginFactoryRelease(release)

        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connector-9", displayName: "Slack 9", listening: true)
        )
        let threadID = UUID().uuidString
        try await repository.upsertMessagingThread(
            MessagingThreadDTO(
                id: threadID,
                pluginID: "slack-connector-9",
                vendorThreadID: "C9",
                title: "#general"
            )
        )
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connector-9",
                vendorThreadID: "C9",
                threadTitle: "#general",
                vendorMessageID: "m1",
                sender: "alice",
                body: "hello",
                createdAt: Date()
            )
        )
        _ = try await repository.claimMessagingAgentHandling(
            pluginID: "slack-connector-9",
            vendorMessageID: "m1"
        )

        try await repository.upsertChatSession(
            ChatSessionDTO(
                applicationName: "ui",
                sessionID: "plugin:slack-connector-9",
                title: "/slack-connector-9",
                createdAt: .now,
                updatedAt: .now,
                metadata: ["pluginID": "slack-connector-9"]
            )
        )
        try await repository.upsertChatSession(
            ChatSessionDTO(
                applicationName: "ui",
                sessionID: "plugin:slack-connector-9:thread:\(threadID)",
                title: "general",
                createdAt: .now,
                updatedAt: .now,
                metadata: ["pluginID": "slack-connector-9", "threadID": threadID]
            )
        )

        let workflow = WorkflowRunRow(
            id: UUID().uuidString,
            kind: WorkflowKind.pluginFactoryCreate.rawValue,
            status: WorkflowRunStatus.completed.rawValue,
            contextJSON: "{}",
            inputJSON: #"{"plugin_id":"slack-connector-9","description":"x"}"#,
            idempotencyKey: nil,
            currentStepID: nil,
            resultJSON: #"{"plugin_id":"slack-connector-9"}"#,
            errorMessage: nil,
            createdAt: .now,
            finishedAt: .now
        )
        try await repository.insertWorkflowRun(workflow)
        _ = try await repository.appendWorkflowEvent(
            workflowID: workflow.id,
            kind: "progress",
            stage: "complete",
            message: "done"
        )

        let result = try await repository.purgePlugin(pluginID: "slack-connector-9")
        XCTAssertEqual(result.removedReleaseCount, 1)
        XCTAssertTrue(result.purgedAssociatedData)
        XCTAssertEqual(result.removedMessagingConnectors, 1)
        XCTAssertEqual(result.removedAgentHandled, 1)
        XCTAssertGreaterThanOrEqual(result.removedChatSessions, 2)
        XCTAssertEqual(result.removedWorkflowRuns, 1)

        let releases = try await repository.listPluginFactoryReleaseSummaries()
        XCTAssertFalse(releases.contains { $0.pluginID == "slack-connector-9" })
        let connectors = try await repository.listMessagingConnectors()
        XCTAssertTrue(connectors.isEmpty)
        let threads = try await repository.listMessagingThreads(pluginID: "slack-connector-9")
        XCTAssertTrue(threads.isEmpty)
        let sessions = try await repository.listRecentChatSessions(applicationName: "ui", limit: 20)
        XCTAssertFalse(sessions.contains { $0.sessionID.contains("slack-connector-9") })
        let missingWorkflow = try await repository.workflowRun(id: workflow.id)
        XCTAssertNil(missingWorkflow)
    }

    func testVersionDeleteKeepsAssociatedDataUntilLastRelease() async throws {
        let repository = try await makeRepository()
        let v1 = makeGoFactoryRelease(pluginID: "weather-tool")
        try await repository.savePluginFactoryRelease(v1)

        let artifact2 = Data("compiled-v2".utf8)
        let guest2 = "package main // v2"
        let manifest2 = "{\"name\":\"weather-tool\",\"extensions\":{\"app.derrick\":{\"entrypoint\":\"./app.derrick/plugin.go\"}}}"
        let files2: [String: Data] = [
            "plugin.json": Data(manifest2.utf8),
            "app.derrick/plugin.go": Data(guest2.utf8),
            "app.derrick/plugin": artifact2,
        ]
        let v2 = PluginFactoryRelease(
            pluginID: "weather-tool",
            version: "1.0.1",
            manifestJSON: manifest2,
            runtimeJSON: "",
            guestSource: guest2,
            compiledArtifact: artifact2,
            skillFiles: [:],
            contentHash: PluginContentHash.hash(files: files2),
            reviewSummary: "approved"
        )
        try await repository.savePluginFactoryRelease(v2)

        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "weather-tool", displayName: "Weather")
        )

        let first = try await repository.purgePlugin(pluginID: "weather-tool", version: "1.0.0")
        XCTAssertEqual(first.removedReleaseCount, 1)
        XCTAssertFalse(first.purgedAssociatedData)
        let connectorsAfterFirst = try await repository.listMessagingConnectors()
        XCTAssertEqual(connectorsAfterFirst.map(\.pluginID), ["weather-tool"])

        let second = try await repository.purgePlugin(pluginID: "weather-tool", version: "1.0.1")
        XCTAssertEqual(second.removedReleaseCount, 1)
        XCTAssertTrue(second.purgedAssociatedData)
        let connectorsAfterSecond = try await repository.listMessagingConnectors()
        XCTAssertTrue(connectorsAfterSecond.isEmpty)
    }

    func testPurgeOrphansRemovesStaleConnectorWithoutRelease() async throws {
        let repository = try await makeRepository()
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "ghost-connector", displayName: "Ghost")
        )
        _ = try await repository.claimMessagingAgentHandling(
            pluginID: "ghost-connector",
            vendorMessageID: "old"
        )

        let orphans = try await repository.purgeOrphanedPluginAssociatedData()
        XCTAssertTrue(orphans.contains { $0.pluginID == "ghost-connector" })
        let connectors = try await repository.listMessagingConnectors()
        XCTAssertTrue(connectors.isEmpty)
    }

    private func makeRepository() async throws -> DBRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        return repository
    }

    private func makeGoFactoryRelease(pluginID: String) -> PluginFactoryRelease {
        let artifact = Data("compiled".utf8)
        let guestSource = "package main"
        let manifestJSON = "{\"name\":\"\(pluginID)\",\"extensions\":{\"app.derrick\":{\"entrypoint\":\"./app.derrick/plugin.go\"}}}"
        let files: [String: Data] = [
            "plugin.json": Data(manifestJSON.utf8),
            "app.derrick/plugin.go": Data(guestSource.utf8),
            "app.derrick/plugin": artifact,
        ]
        return PluginFactoryRelease(
            pluginID: pluginID,
            version: "1.0.0",
            manifestJSON: manifestJSON,
            runtimeJSON: "",
            guestSource: guestSource,
            compiledArtifact: artifact,
            skillFiles: [:],
            contentHash: PluginContentHash.hash(files: files),
            reviewSummary: "approved"
        )
    }
}
