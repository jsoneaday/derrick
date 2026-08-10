import XCTest
import SQLite3
import AgentRuntime
import ServiceContracts
@testable import DBRepository

final class DBAgentOrchestrationTests: XCTestCase {
    func testMigrationCreatesOrchestrationTables() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let url = await repository.databaseURL
        XCTAssertTrue(try tableExists(named: "chat_sessions", at: url))
        XCTAssertTrue(try tableExists(named: "agents", at: url))
        XCTAssertTrue(try tableExists(named: "agent_turns", at: url))
    }

    func testDBAgentDirectoryPersistsUserFacingAgent() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let sessionID = UUID().uuidString
        let directory = try await DBAgentDirectory(
            repository: repository,
            applicationName: "ui",
            sessionID: sessionID
        )

        let record = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        XCTAssertEqual(record.ref.agentID, AgentRef.userFacingAgentID)

        let reloaded = try await DBAgentDirectory(
            repository: repository,
            applicationName: "ui",
            sessionID: sessionID
        )
        let restored = await reloaded.record(for: record.ref)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.role, .userFacing)
    }

    func testListRecentChatSessionsOrdersByUpdatedAt() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let older = ChatSessionDTO(applicationName: "ui", sessionID: "older", updatedAt: .now.addingTimeInterval(-120))
        let newer = ChatSessionDTO(applicationName: "ui", sessionID: "newer", updatedAt: .now)
        try await repository.upsertChatSession(older)
        try await repository.upsertChatSession(newer)

        let sessions = try await repository.listRecentChatSessions(applicationName: "ui", limit: 5)
        XCTAssertEqual(sessions.map(\.sessionID), ["newer", "older"])
    }

    func testWorkerAgentPersistsToDatabase() async throws {
        let repository = try makeTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let sessionID = UUID().uuidString
        let directory = try await DBAgentDirectory(
            repository: repository,
            applicationName: "ui",
            sessionID: sessionID
        )
        _ = try await directory.ensureUserFacingAgent(sessionID: sessionID)
        let workerRef = AgentRef(sessionID: sessionID, agentID: "worker-test")
        _ = try await directory.register(
            AgentRecord(
                ref: workerRef,
                role: .worker,
                parentAgentID: AgentRef.userFacingAgentID,
                status: .created,
                goal: "test worker"
            )
        )

        let records = try await repository.loadAgentRecords(applicationName: "ui", sessionID: sessionID)
        XCTAssertTrue(records.contains { $0.ref.agentID == "worker-test" && $0.role == .worker })
    }

    private func makeTestRepository() throws -> DBRepository {
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

    private func tableExists(named name: String, at databaseURL: URL) throws -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            return false
        }
        defer { sqlite3_close_v2(handle) }

        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
