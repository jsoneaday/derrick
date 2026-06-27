import Foundation
import SQLite3

public struct DBRepositoryMigration: Hashable, Sendable {
    public let version: Int
    public let name: String
    public let upResourceName: String
    public let downResourceName: String

    public init(version: Int, name: String) {
        self.version = version
        self.name = name
        self.upResourceName = String(format: "%04d_%@.up", version, name)
        self.downResourceName = String(format: "%04d_%@.down", version, name)
    }
}

public extension DBRepository {
    static let migrations: [DBRepositoryMigration] = [
        DBRepositoryMigration(version: 1, name: "memory_sessions"),
        DBRepositoryMigration(version: 2, name: "memory_records")
    ]

    static var latestMigrationVersion: Int {
        migrations.last?.version ?? 0
    }

    func migrate(username: String, password: String, to targetVersion: Int? = nil) throws -> URL {
        try authenticate(username: username, password: password)
        try Self.ensureDirectory(at: databaseDirectoryURL)

        let target = targetVersion ?? Self.latestMigrationVersion
        guard target >= 0, target <= Self.latestMigrationVersion else {
            throw DBRepositoryError.unsupportedMigrationVersion(target)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = String(cString: sqlite3_errstr(status))
            if let handle {
                sqlite3_close(handle)
            }
            throw DBRepositoryError.sqliteOpenFailed(message)
        }

        defer {
            sqlite3_close(handle)
        }

        let currentVersion = try Self.schemaVersion(on: handle)
        if currentVersion < target {
            for version in (currentVersion + 1)...target {
                try Self.applyMigration(version: version, direction: .up, on: handle)
            }
        } else if currentVersion > target {
            for version in stride(from: currentVersion, to: target, by: -1) {
                try Self.applyMigration(version: version, direction: .down, on: handle)
            }
        }

        return databaseURL
    }
}

private enum DBRepositoryMigrationDirection {
    case up
    case down
}

private extension DBRepository {
    static func schemaVersion(on handle: OpaquePointer?) throws -> Int {
        let sql = "PRAGMA user_version;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(handle: handle, fallback: "Unable to read the schema version.")
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError(handle: handle, fallback: "Unable to read the schema version.")
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    static func applyMigration(version: Int, direction: DBRepositoryMigrationDirection, on handle: OpaquePointer?) throws {
        guard let migration = migrations.first(where: { $0.version == version }) else {
            throw DBRepositoryError.unsupportedMigrationVersion(version)
        }

        let resourceName = switch direction {
        case .up: migration.upResourceName
        case .down: migration.downResourceName
        }

        let sql = try loadMigrationSQL(named: resourceName)

        do {
            try execute("BEGIN IMMEDIATE TRANSACTION;", on: handle)
            try execute(sql, on: handle)

            let appliedVersion = switch direction {
            case .up: version
            case .down: version - 1
            }
            try execute("PRAGMA user_version = \(appliedVersion);", on: handle)
            try execute("COMMIT;", on: handle)
        } catch {
            _ = try? execute("ROLLBACK;", on: handle)
            throw error
        }
    }

    static func loadMigrationSQL(named resourceName: String) throws -> String {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let migrationsDirectoryURL = sourceFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Migrations", isDirectory: true)
        let url = migrationsDirectoryURL.appendingPathComponent("\(resourceName).sql")

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DBRepositoryError.missingMigrationResource(resourceName)
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw DBRepositoryError.missingMigrationResource(resourceName)
        }
    }

    static func execute(_ sql: String, on handle: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(status))
            sqlite3_free(errorMessage)
            throw sqliteError(handle: handle, fallback: message)
        }
    }

    static func sqliteError(handle: OpaquePointer?, fallback: String) -> DBRepositoryError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) }
        return .sqliteMigrationFailed(message ?? fallback)
    }
}
