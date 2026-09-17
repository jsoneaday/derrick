import DBRepository
import DerrickBackend
import FactoryHarnessSupport
import Foundation
import Structure

/// One-shot cleanup: removes legacy reference Slack factory releases and messaging connectors.
@main
enum SlackConnectorInstallReference {
    static func main() async {
        do {
            try await purge()
            fputs("SlackConnectorInstallReference: purged legacy Slack reference connectors.\n", stderr)
        } catch {
            fputs("SlackConnectorInstallReference: FAILED — \(error)\n", stderr)
            exit(1)
        }
    }

    private static func purge() async throws {
        let directory = try DerrickAppSupport.databaseDirectory()
        let repository = DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: DerrickAppSupport.defaultApplicationName,
                databaseName: "derrick",
                databaseDirectoryURL: directory,
                username: "ui",
                password: "ui"
            )
        )
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        let removed = try await LegacySlackConnectorPurge.run(repository: repository)
        fputs("[purge] removed \(removed) Slack factory release(s)\n", stderr)
    }
}
