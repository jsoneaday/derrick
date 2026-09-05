import Foundation

public struct DBRepositoryConfiguration: Equatable, Sendable {
    public let applicationName: String
    public let databaseName: String
    public let databaseDirectoryURL: URL
    public let username: String
    public let password: String

    public init(
        applicationName: String,
        databaseName: String,
        databaseDirectoryURL: URL,
        username: String,
        password: String
    ) {
        self.applicationName = applicationName
        self.databaseName = databaseName
        self.databaseDirectoryURL = databaseDirectoryURL
        self.username = username
        self.password = password
    }

    public var databaseFileURL: URL {
        databaseDirectoryURL.appendingPathComponent("\(databaseName).sqlite3")
    }
}

public enum DBRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case invalidDatabaseDirectory(URL)
    case sqliteOpenFailed(String)
    case sqliteCloseFailed(String)
    case sqliteMigrationFailed(String)
    case sqliteOperationFailed(String)
    case authenticationFailed
    case unsupportedMigrationVersion(Int)
    case missingMigrationResource(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDatabaseDirectory(let url):
            return "The database directory is not valid: \(url.path)"
        case .sqliteOpenFailed(let message):
            return "Unable to open the SQLite database: \(message)"
        case .sqliteCloseFailed(let message):
            return "Unable to close the SQLite database: \(message)"
        case .sqliteMigrationFailed(let message):
            return "Unable to migrate the SQLite database: \(message)"
        case .sqliteOperationFailed(let message):
            return "Unable to operate on the SQLite database: \(message)"
        case .authenticationFailed:
            return "The supplied credentials do not match the repository configuration."
        case .unsupportedMigrationVersion(let version):
            return "Unsupported migration version: \(version)"
        case .missingMigrationResource(let name):
            return "Missing migration resource: \(name)"
        }
    }
}
