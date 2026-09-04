import XCTest
import SQLite3
import Plugin
import ServiceContracts
@testable import DBRepository

final class DBMessagingTests: XCTestCase {
    func testMigrationCreatesMessagingTables() async throws {
        let repository = try makeRepository()
        let url = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        XCTAssertTrue(try tableExists(named: "messaging_connectors", at: url))
        XCTAssertTrue(try tableExists(named: "messaging_threads", at: url))
        XCTAssertTrue(try tableExists(named: "messaging_messages", at: url))
        XCTAssertEqual(try schemaVersion(at: url), DatabaseSchema.latestVersion)
    }

    func testInsertMessageIsIdempotentAndPagesNewestAtBottom() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "test-connector", displayName: "Test Connector")
        )
        let thread = MessagingThreadDTO(
            pluginID: "test-connector",
            vendorThreadID: "C123",
            title: "#general"
        )
        try await repository.upsertMessagingThread(thread)

        let older = MessagingMessageDTO(
            threadID: thread.id,
            vendorMessageID: "1",
            direction: .inbound,
            sender: "alice",
            body: "hello",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = MessagingMessageDTO(
            threadID: thread.id,
            vendorMessageID: "2",
            direction: .inbound,
            sender: "bob",
            body: "world",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let first = try await repository.insertMessagingMessage(older, incrementUnread: true)
        let duplicate = try await repository.insertMessagingMessage(older, incrementUnread: true)
        _ = try await repository.insertMessagingMessage(newer, incrementUnread: true)

        XCTAssertTrue(first.inserted)
        XCTAssertFalse(duplicate.inserted)

        let page = try await repository.listMessagingMessages(threadID: thread.id, limit: 100)
        XCTAssertEqual(page.map(\.body), ["hello", "world"])

        let olderPage = try await repository.listMessagingMessages(
            threadID: thread.id,
            before: newer.cursor,
            limit: 100
        )
        XCTAssertEqual(olderPage.map(\.body), ["hello"])

        let reloaded = try await repository.messagingThread(id: thread.id)
        XCTAssertEqual(reloaded?.unreadCount, 2)

        let connectors = try await repository.listMessagingConnectors()
        XCTAssertEqual(connectors.first?.unreadCount, 2)

        try await repository.clearMessagingThreadUnread(id: thread.id)
        try await repository.setMessagingThreadMuted(id: thread.id, muted: true)
        let muted = try await repository.messagingThread(id: thread.id)
        XCTAssertEqual(muted?.unreadCount, 0)
        XCTAssertEqual(muted?.muted, true)
    }

    func testInboundPersistIsAtomicAndDoesNotClobberMute() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "test-connector", displayName: "Test Connector")
        )

        let first = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "test-connector",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "ts-1",
                sender: "alice",
                body: "hello",
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        XCTAssertTrue(first.inserted)
        XCTAssertEqual(first.thread.unreadCount, 1)

        try await repository.setMessagingThreadMuted(id: first.thread.id, muted: true)
        try await repository.clearMessagingThreadUnread(id: first.thread.id)

        let renamed = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "test-connector",
                vendorThreadID: "C123",
                threadTitle: "#general-renamed",
                vendorMessageID: "ts-2",
                sender: "bob",
                body: "later",
                createdAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        XCTAssertTrue(renamed.inserted)
        XCTAssertEqual(renamed.thread.id, first.thread.id)
        XCTAssertEqual(renamed.thread.title, "#general-renamed")
        XCTAssertEqual(renamed.thread.muted, true)
        XCTAssertEqual(renamed.thread.unreadCount, 0)

        let duplicate = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "test-connector",
                vendorThreadID: "C123",
                threadTitle: "#general-renamed",
                vendorMessageID: "ts-2",
                sender: "bob",
                body: "later",
                createdAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        XCTAssertFalse(duplicate.inserted)
        XCTAssertEqual(duplicate.message.id, renamed.message.id)
        XCTAssertEqual(duplicate.thread.unreadCount, 0)
        XCTAssertEqual(duplicate.thread.muted, true)
    }

    func testSameTimestampPagesByIdCursor() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "test-connector", displayName: "Test Connector")
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "test-connector",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "a",
                sender: "alice",
                body: "one",
                createdAt: stamp
            )
        )
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "test-connector",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "b",
                sender: "bob",
                body: "two",
                createdAt: stamp
            )
        )
        let window = try await repository.listMessagingMessages(
            threadID: first.thread.id,
            limit: 100
        )
        XCTAssertEqual(window.count, 2)
        let olderPage = try await repository.listMessagingMessages(
            threadID: first.thread.id,
            before: window.last?.cursor,
            limit: 100
        )
        XCTAssertEqual(olderPage.map(\.id), window.dropLast().map(\.id))
    }

    func testConcurrentInboundPersistDoesNotDoubleUnread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )
        let firstRepo = DBRepository(configuration: configuration)
        let secondRepo = DBRepository(configuration: configuration)
        _ = try await firstRepo.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await firstRepo.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "test-connector", displayName: "Test Connector")
        )

        let record = MessagingInboundRecord(
            pluginID: "test-connector",
            vendorThreadID: "C123",
            threadTitle: "#general",
            vendorMessageID: "same-event",
            sender: "alice",
            body: "hello",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        async let left = firstRepo.persistMessagingInbound(record)
        async let right = secondRepo.persistMessagingInbound(record)
        let results = try await [left, right]
        XCTAssertEqual(results.filter(\.inserted).count, 1)
        XCTAssertEqual(Set(results.map(\.message.id)).count, 1)
        XCTAssertEqual(results.map(\.thread.unreadCount).max(), 1)
    }

    func testSetMessagingConnectorListening() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "test-connector", displayName: "Test Connector", listening: false)
        )
        try await repository.setMessagingConnectorListening(pluginID: "test-connector", listening: true)
        let connectors = try await repository.listMessagingConnectors(listeningOnly: true)
        XCTAssertEqual(connectors.map(\.pluginID), ["test-connector"])
        XCTAssertTrue(connectors.first?.listening == true)
    }

    func testPruneMessagingConnectorsRemovesOrphansAndKeepsFactoryConnectors() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Legacy Slack")
        )
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connector", displayName: "Slack Connector")
        )
        try await repository.upsertMessagingThread(
            MessagingThreadDTO(
                pluginID: "slack-connection",
                vendorThreadID: "C1",
                title: "#general"
            )
        )

        try await repository.pruneMessagingConnectors(keeping: ["slack-connector"])

        let connectors = try await repository.listMessagingConnectors()
        XCTAssertEqual(connectors.map(\.pluginID), ["slack-connector"])
        let threads = try await repository.listMessagingThreads(pluginID: "slack-connection")
        XCTAssertTrue(threads.isEmpty)
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

    private func tableExists(named name: String, at databaseURL: URL) throws -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            return false
        }
        defer { sqlite3_close_v2(handle) }
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func schemaVersion(at url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            return -1
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK, let statement else {
            return -1
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(statement, 0))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
