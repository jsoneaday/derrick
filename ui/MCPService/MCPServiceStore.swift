import Foundation
import DBRepository
import Structure

/// Shared SQLite for MCPService (same host-container path as UI / AgentService).
actor MCPServiceStore {
    static let shared = MCPServiceStore()

    private var repository: DBRepository?

    func sharedRepository() async throws -> DBRepository {
        if let repository { return repository }
        let directory = try DerrickAppSupport.databaseDirectory()
        let repo = DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: DerrickAppSupport.defaultApplicationName,
                databaseName: "derrick",
                databaseDirectoryURL: directory,
                username: "ui",
                password: "ui"
            )
        )
        _ = try await repo.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        repository = repo
        let path = await repo.databaseURL.path
        fputs("[MCPService] shared DB: \(path)\n", stderr)
        return repo
    }

    func log(
        level: ServiceLogLevel,
        message: String,
        code: String? = nil,
        detailJSON: String? = nil
    ) async {
        do {
            let repo = try await sharedRepository()
            try await repo.appendServiceLog(
                ServiceLogEntry(
                    service: DerrickServiceID.mcp.shortName,
                    level: level,
                    code: code,
                    message: message,
                    detailJSON: detailJSON
                )
            )
        } catch {
            fputs("[MCPService] log failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func databasePath() async -> String? {
        try? await sharedRepository().databaseURL.path
    }
}
