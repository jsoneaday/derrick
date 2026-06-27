import XCTest
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
}
