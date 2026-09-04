import XCTest
import Plugin
import ServiceContracts
@testable import DBRepository

final class ConnectorMessagingPersistenceTests: XCTestCase {
    func testApplyPersistsThreadsAndInboundMessages() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "test-connector", displayName: "Test")
        )

        let result = ConnectorMessagingResult(
            threads: [
                ConnectorMessagingThread(vendorThreadID: "C1", title: "#general"),
            ],
            messages: [
                ConnectorMessagingMessage(
                    vendorThreadID: "C1",
                    vendorMessageID: "1.0",
                    direction: .inbound,
                    sender: "alice",
                    body: "hello",
                    createdAt: Date(timeIntervalSince1970: 1_000)
                ),
            ]
        )
        let inserted = try await ConnectorMessagingPersistence.apply(
            result,
            pluginID: "test-connector",
            repository: repository
        )
        XCTAssertEqual(inserted.count, 1)
        let threads = try await repository.listMessagingThreads(pluginID: "test-connector")
        XCTAssertEqual(threads.count, 1)
        let messages = try await repository.listMessagingMessages(threadID: threads[0].id, limit: 10)
        XCTAssertEqual(messages.map(\.body), ["hello"])
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
}
