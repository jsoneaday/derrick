import XCTest
import SQLite3
@testable import DBRepository

final class DBRepositoryTests: XCTestCase {
    func testCreatesEmptySQLiteDatabaseFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        let url = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "derrick.sqlite3")
    }

    func testRejectsInvalidCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        do {
            _ = try await repository.createEmptyDatabaseIfNeeded(username: "wrong", password: "wrong")
            XCTFail("Expected authentication to fail")
        } catch DBRepositoryError.authenticationFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMigratesSchemaUpAndDown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = DBRepositoryConfiguration(
            applicationName: "ui",
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "app-user",
            password: "app-secret"
        )

        let repository = DBRepository(configuration: configuration)
        let url = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        XCTAssertEqual(try schemaVersion(at: url), 2)
        XCTAssertTrue(try tableExists(named: "memory_sessions", at: url))
        XCTAssertTrue(try tableExists(named: "memory_records", at: url))

        _ = try await repository.migrate(username: "app-user", password: "app-secret", to: 0)

        XCTAssertEqual(try schemaVersion(at: url), 0)
        XCTAssertFalse(try tableExists(named: "memory_sessions", at: url))
        XCTAssertFalse(try tableExists(named: "memory_records", at: url))
    }

    private func schemaVersion(at url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "DBRepositoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite database at \(url.path)"])
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "DBRepositoryTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to prepare schema version query"])
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "DBRepositoryTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to read schema version"])
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    private func tableExists(named tableName: String, at url: URL) throws -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "DBRepositoryTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite database at \(url.path)"])
        }
        defer { sqlite3_close(handle) }

        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(tableName)' LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "DBRepositoryTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unable to prepare table existence query"])
        }
        defer { sqlite3_finalize(statement) }

        return sqlite3_step(statement) == SQLITE_ROW
    }
}
