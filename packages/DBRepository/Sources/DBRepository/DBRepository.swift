import Foundation
import SQLite3
@_exported import MemorySystem
import Structure

public actor DBRepository {
    private let configuration: DBRepositoryConfiguration

    public init(configuration: DBRepositoryConfiguration) {
        self.configuration = configuration
    }

    public var databaseURL: URL {
        configuration.databaseFileURL
    }

    public var databaseDirectoryURL: URL {
        configuration.databaseDirectoryURL
    }

    public var applicationName: String {
        configuration.applicationName
    }

    public func createEmptyDatabaseIfNeeded(username: String, password: String) throws -> URL {
        let url = try migrateSessionMemory(username: username, password: password)
        return url
    }

    public func authenticate(username: String, password: String) throws {
        guard username == configuration.username, password == configuration.password else {
            throw DBRepositoryError.authenticationFailed
        }
    }

    static func ensureDirectory(at url: URL) throws {
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
