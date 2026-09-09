import Foundation
import Structure

public enum DatabaseSchema {
    public static let latestVersion = 8

    public static func migrationSQL(version: Int, isUp: Bool) throws -> String {
        let migrationName = String(format: "%04d_%@", version, migrationFileBaseName(for: version))
        let fileSuffix = isUp ? "up" : "down"
        let resourceName = "\(migrationName).\(fileSuffix)"
        let fileURL = try resourceURL(name: resourceName)

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
            return "initial_schema"
        case 2:
            return "schema_refresh"
        case 3:
            return "messaging_listening_since"
        case 4:
            return "messaging_reply_threads"
        case 5:
            return "news_readers"
        case 6:
            return "agent_profiles"
        case 7:
            return "messaging_agent_handled"
        case 8:
            return "messaging_thread_default_profile"
        default:
            return "unknown"
        }
    }

    private static func resourceURL(name: String) throws -> URL {
        guard let fileURL = Bundle.module.url(forResource: name, withExtension: "sql") else {
            throw CocoaError(.fileNoSuchFile)
        }

        return fileURL
    }
}
