import Foundation
import DBRepository
import ServiceContracts

actor JobServiceStore {
    static let shared = JobServiceStore()

    private var repository: DBRepository?

    func sharedRepository() async throws -> DBRepository {
        if let repository { return repository }
        let directory = try DerrickAppSupport.databaseDirectory()
        let config = DBRepositoryConfiguration(
            applicationName: DerrickAppSupport.defaultApplicationName,
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "ui",
            password: "ui"
        )
        let repo = DBRepository(configuration: config)
        _ = try await repo.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        repository = repo
        let path = await repo.databaseURL.path
        fputs("[JobService] shared DB: \(path)\n", stderr)
        return repo
    }

    func databasePath() async -> String? {
        try? await sharedRepository().databaseURL.path
    }

    func log(level: ServiceLogLevel, message: String, code: String, detailJSON: String? = nil) async {
        do {
            let repo = try await sharedRepository()
            try await repo.appendServiceLog(
                ServiceLogEntry(
                    service: DerrickServiceID.job.shortName,
                    level: level,
                    code: code,
                    message: message,
                    detailJSON: detailJSON
                )
            )
        } catch {
            fputs("[JobService] log failed: \(error.localizedDescription)\n", stderr)
        }
    }
}
