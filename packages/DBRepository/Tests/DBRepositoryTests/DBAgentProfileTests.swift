import XCTest
@testable import DBRepository
import Structure

final class DBAgentProfileTests: XCTestCase {
    func testAgentProfileRoundTripAndBuiltinDeleteGuard() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let profile = AgentProfile(
            displayName: "Reviewer",
            handle: "reviewer",
            instructions: "Review code carefully.",
            modelJSON: Data(#"{"openai":"gpt-5.6-luna"}"#.utf8),
            rag: AgentProfileRAGConfig(retrievalLimit: 8)
        )
        try await repository.upsertAgentProfile(profile)

        let listed = try await repository.listAgentProfiles()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].handle, "reviewer")
        XCTAssertEqual(listed[0].rag.retrievalLimit, 8)

        let loaded = try await repository.agentProfile(handle: "reviewer")
        XCTAssertEqual(loaded?.displayName, "Reviewer")

        let builtin = AgentProfile.orchestratorDefault(modelJSON: Data(#"{"openai":"gpt-5.6-luna"}"#.utf8))
        try await repository.upsertAgentProfile(builtin)
        try await repository.deleteAgentProfile(id: builtin.id)
        let stillThere = try await repository.agentProfile(handle: AgentProfileHandle.orchestrator)
        XCTAssertNotNil(stillThere)

        try await repository.deleteAgentProfile(id: profile.id)
        let remaining = try await repository.listAgentProfiles()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].handle, AgentProfileHandle.orchestrator)
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
