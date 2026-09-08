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
