import Foundation
import DBRepository
import Structure

/// Shared SQLite access for AgentService (same path as sandboxed UI + policy seed).
actor AgentServiceStore {
    static let shared = AgentServiceStore()

    private var repository: DBRepository?
    private var didSeedPolicy = false

    func sharedRepository() async throws -> DBRepository {
        if let repository {
            if !didSeedPolicy {
                try await seedPolicyIfNeeded(repository: repository)
            }
            return repository
        }
        let directory = try DerrickAppSupport.databaseDirectory()
        // Use the same bootstrap as UI: migrations + baseline policy rules.
        // Empty rule tables fail closed and strip all model chunks.
        let repo = try await ConversationModel.makeMemoryStore(
            applicationName: DerrickAppSupport.defaultApplicationName,
            databaseDirectoryURL: directory
        )
        didSeedPolicy = true
        repository = repo
        let path = await repo.databaseURL.path
        fputs("[AgentService] shared DB: \(path)\n", stderr)
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
                    service: DerrickServiceID.agent.shortName,
                    level: level,
                    code: code,
                    message: message,
                    detailJSON: detailJSON
                )
            )
        } catch {
            fputs("[AgentService] log failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func databasePath() async -> String? {
        try? await sharedRepository().databaseURL.path
    }

    private func seedPolicyIfNeeded(repository: DBRepository) async throws {
        // Re-open path via makeMemoryStore only when we already hold a repo without seed flag
        // (shouldn't happen if sharedRepository always seeds). Idempotent seed is inside makeMemoryStore.
        _ = try await ConversationModel.makeMemoryStore(
            applicationName: DerrickAppSupport.defaultApplicationName,
            databaseDirectoryURL: await repository.databaseDirectoryURL
        )
        didSeedPolicy = true
    }
}
