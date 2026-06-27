import Foundation

public enum MemoryDatabaseSchema {
    public static let latestVersion = 2

    public static func migrationSQL(version: Int, isUp: Bool) throws -> String {
        let migrationName = String(format: "%04d_%@", version, migrationFileBaseName(for: version))
        let fileSuffix = isUp ? "up" : "down"
        let fileURL = migrationsDirectoryURL()
            .appendingPathComponent("\(migrationName).\(fileSuffix).sql")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func migrationFileBaseName(for version: Int) -> String {
        switch version {
        case 1:
            return "memory_sessions"
        case 2:
            return "memory_records"
        default:
            return "unknown"
        }
    }

    private static func migrationsDirectoryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Migrations", isDirectory: true)
    }
}
