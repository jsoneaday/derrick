import Foundation
import SQLite3

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
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDatabaseDirectory(let url):
            return "The database directory is not valid: \(url.path)"
        case .sqliteOpenFailed(let message):
            return "Unable to open the SQLite database: \(message)"
        case .sqliteCloseFailed(let message):
            return "Unable to close the SQLite database: \(message)"
        case .authenticationFailed:
            return "The supplied credentials do not match the repository configuration."
        }
    }
}

public actor DBRepository {
    private let configuration: DBRepositoryConfiguration

    public init(configuration: DBRepositoryConfiguration) {
        self.configuration = configuration
    }

    public var databaseURL: URL {
        configuration.databaseFileURL
    }

    public var applicationName: String {
        configuration.applicationName
    }

    public func createEmptyDatabaseIfNeeded(username: String, password: String) throws -> URL {
        try authenticate(username: username, password: password)
        try Self.ensureDirectory(at: configuration.databaseDirectoryURL)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        let status = sqlite3_open_v2(configuration.databaseFileURL.path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = String(cString: sqlite3_errstr(status))
            if let handle {
                sqlite3_close(handle)
            }
            throw DBRepositoryError.sqliteOpenFailed(message)
        }

        let closeStatus = sqlite3_close(handle)
        guard closeStatus == SQLITE_OK else {
            let message = String(cString: sqlite3_errstr(closeStatus))
            throw DBRepositoryError.sqliteCloseFailed(message)
        }

        return configuration.databaseFileURL
    }

    public func authenticate(username: String, password: String) throws {
        guard username == configuration.username, password == configuration.password else {
            throw DBRepositoryError.authenticationFailed
        }
    }

    private static func ensureDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            return
        }

        if exists && !isDirectory.boolValue {
            throw DBRepositoryError.invalidDatabaseDirectory(url)
        }

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
