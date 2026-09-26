import Foundation
import DBRepository
import Structure

/// Shared SQLite for MCPService (same host-container path as UI / AgentService).
actor MCPServiceStore {
    static let shared = MCPServiceStore()

    private var repository: DBRepository?
    private var didSeedPolicy = false

    func sharedRepository() async throws -> DBRepository {
        if let repository {
            if !didSeedPolicy {
                try await seedBaselinePolicyIfNeeded(repository)
                didSeedPolicy = true
            }
            return repository
        }
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
        try await seedBaselinePolicyIfNeeded(repo)
        didSeedPolicy = true
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

    /// Idempotent baseline so effector admission works even if UI has not launched yet.
    private func seedBaselinePolicyIfNeeded(_ repository: DBRepository) async throws {
        let app = DerrickAppSupport.defaultApplicationName
        try await DefaultGuardrailPolicySeeds.seedWorkflowStartRulesIfNeeded(
            store: repository,
            applicationName: app
        )
        var rules: [PolicyRule] = AllowedMCPTool.allCases.map { tool in
            PolicyRule(
                applicationName: app,
                name: "allow-\(tool.rawValue)",
                scope: "tool_invocation",
                matcherJSON: #"{"tool_name":"\#(tool.rawValue)"}"#,
                outcomeJSON: #"{"action":"allow"}"#,
                priority: 1
            )
        }
        rules += ["tool_search", "tool", "tool_batch"].map { name in
            PolicyRule(
                applicationName: app,
                name: "allow-\(name)",
                scope: "tool_invocation",
                matcherJSON: #"{"tool_name":"\#(name)"}"#,
                outcomeJSON: #"{"action":"allow"}"#,
                priority: 1
            )
        }
        for rule in rules {
            let existing = try await repository.loadRules(applicationName: app, scope: rule.scope)
            guard existing.contains(where: { $0.name == rule.name }) == false else { continue }
            try await repository.saveRule(rule)
        }
    }
}
