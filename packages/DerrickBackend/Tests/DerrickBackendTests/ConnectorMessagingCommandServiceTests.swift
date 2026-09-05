import DBRepository
import Foundation
import Plugin
import Structure
import Testing
@testable import DerrickBackend

@Suite struct ConnectorMessagingCommandServiceTests {
    @Test func pollFailsForUnknownOperation() async throws {
        await #expect(throws: ConnectorMessagingCommandError.operationNotFound) {
            _ = try await ConnectorMessagingCommandService.shared.poll(
                ConnectorOperationPollRequest(operationID: "missing")
            )
        }
    }

    @Test func submitRejectsDuplicateOperationID() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        let request = ConnectorOperationRequest(
            operationID: "dup-op",
            pluginID: "slack-connector",
            kind: .bootstrap
        )
        nonisolated(unsafe) let repo = repository
        let provider: @Sendable () async throws -> DBRepository = { repo }
        _ = try await ConnectorMessagingCommandService.shared.submit(request, repositoryProvider: provider)
        await #expect(throws: ConnectorMessagingCommandError.duplicateOperationID) {
            _ = try await ConnectorMessagingCommandService.shared.submit(request, repositoryProvider: provider)
        }
        _ = try? await ConnectorMessagingCommandService.shared.poll(
            ConnectorOperationPollRequest(operationID: "dup-op")
        )
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
