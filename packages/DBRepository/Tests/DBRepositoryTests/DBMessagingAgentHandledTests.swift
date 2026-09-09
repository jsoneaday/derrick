import XCTest
@testable import DBRepository
import Structure

final class DBMessagingAgentHandledTests: XCTestCase {
    func testClaimMessagingAgentHandlingIsIdempotent() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let firstClaim = try await repository.claimMessagingAgentHandling(
            pluginID: "slack-connection",
            vendorMessageID: "1710000000.000100"
        )
        XCTAssertTrue(firstClaim)
        let secondClaim = try await repository.claimMessagingAgentHandling(
            pluginID: "slack-connection",
            vendorMessageID: "1710000000.000100"
        )
        XCTAssertFalse(secondClaim)
    }

    func testListUnclaimedInboundExcludesClaimedRows() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack")
        )
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "1710000002.000200",
                sender: "U07FKG8DV19",
                body: "$orchestrator tell me about yourself"
            )
        )
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "1710000002.000201",
                sender: "U07FKG8DV19",
                body: "hello without mention"
            )
        )

        let unclaimed = try await repository.listUnclaimedInboundMessagingMessages()
        XCTAssertEqual(Set(unclaimed.compactMap(\.message.vendorMessageID)), [
            "1710000002.000200",
            "1710000002.000201"
        ])

        let claimed = try await repository.claimMessagingAgentHandling(
            pluginID: "slack-connection",
            vendorMessageID: "1710000002.000200"
        )
        XCTAssertTrue(claimed)
        let remaining = try await repository.listUnclaimedInboundMessagingMessages()
        XCTAssertEqual(remaining.compactMap(\.message.vendorMessageID), ["1710000002.000201"])
    }

    func testReleaseUnansweredProfileTokenClaims() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack")
        )
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "1710000002.000200",
                sender: "U07FKG8DV19",
                body: "$developer tell me about yourself"
            )
        )
        let claimed = try await repository.claimMessagingAgentHandling(
            pluginID: "slack-connection",
            vendorMessageID: "1710000002.000200"
        )
        XCTAssertTrue(claimed)
        try await repository.releaseUnansweredProfileTokenClaims()
        let unclaimed = try await repository.listUnclaimedInboundMessagingMessages()
        XCTAssertEqual(unclaimed.compactMap(\.message.vendorMessageID), ["1710000002.000200"])
    }

    func testReleaseMessagingAgentHandlingAllowsRetry() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        let first = try await repository.claimMessagingAgentHandling(
            pluginID: "slack-connection",
            vendorMessageID: "171.9"
        )
        XCTAssertTrue(first)
        try await repository.releaseMessagingAgentHandling(
            pluginID: "slack-connection",
            vendorMessageID: "171.9"
        )
        let retry = try await repository.claimMessagingAgentHandling(
            pluginID: "slack-connection",
            vendorMessageID: "171.9"
        )
        XCTAssertTrue(retry)
    }

    private func makeRepository() throws -> DBRepository {
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
        return DBRepository(configuration: configuration)
    }
}
