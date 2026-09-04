import XCTest
import ServiceContracts
@testable import DBRepository

final class WorkflowRuntimePersistenceTests: XCTestCase {
    func testWorkflowIdempotencyKeyIsStable() {
        let first = WorkflowRuntimeIdempotency.key(
            sessionID: "session",
            kind: .pluginFactoryCreate,
            inputJSON: #"{"goal":"slack"}"#
        )
        let second = WorkflowRuntimeIdempotency.key(
            sessionID: "session",
            kind: .pluginFactoryCreate,
            inputJSON: #"{"goal":"slack"}"#
        )
        let different = WorkflowRuntimeIdempotency.key(
            sessionID: "session",
            kind: .pluginFactoryCreate,
            inputJSON: #"{"goal":"discord"}"#
        )
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, different)
    }

    func testWorkflowRunRoundTrip() async throws {
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

        let idempotencyKey = WorkflowRuntimeIdempotency.key(
            sessionID: "s1",
            kind: .pluginFactoryCreate,
            inputJSON: "slack connector"
        )
        let row = WorkflowRunRow(
            id: "wf-1",
            kind: WorkflowKind.pluginFactoryCreate.rawValue,
            status: WorkflowRunStatus.running.rawValue,
            contextJSON: "{}",
            inputJSON: "slack connector",
            idempotencyKey: idempotencyKey,
            createdAt: Date()
        )
        try await repository.insertWorkflowRun(row)
        let loaded = try await repository.workflowRun(idempotencyKey: idempotencyKey)
        XCTAssertEqual(loaded?.id, "wf-1")

        let seq = try await repository.appendWorkflowEvent(
            workflowID: "wf-1",
            kind: "progress",
            stage: "crawl",
            message: "Crawling docs"
        )
        XCTAssertEqual(seq, 1)

        let events = try await repository.workflowEvents(workflowID: "wf-1", afterSeq: 0)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].message, "Crawling docs")
    }

    func testFailedWorkflowDoesNotBlockNewRunWithSameIdempotencyKey() async throws {
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

        let idempotencyKey = WorkflowRuntimeIdempotency.key(
            sessionID: "s1",
            kind: .pluginFactoryCreate,
            inputJSON: "slack connector"
        )
        let failed = WorkflowRunRow(
            id: "wf-failed",
            kind: WorkflowKind.pluginFactoryCreate.rawValue,
            status: WorkflowRunStatus.failed.rawValue,
            contextJSON: "{}",
            inputJSON: "slack connector",
            idempotencyKey: idempotencyKey,
            createdAt: Date(),
            finishedAt: Date()
        )
        try await repository.insertWorkflowRun(failed)

        let retry = WorkflowRunRow(
            id: "wf-retry",
            kind: WorkflowKind.pluginFactoryCreate.rawValue,
            status: WorkflowRunStatus.running.rawValue,
            contextJSON: "{}",
            inputJSON: "slack connector",
            idempotencyKey: idempotencyKey,
            createdAt: Date()
        )
        try await repository.insertWorkflowRun(retry)

        let active = try await repository.workflowRun(idempotencyKey: idempotencyKey)
        XCTAssertEqual(active?.id, "wf-retry")
    }
}
