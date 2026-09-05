import Foundation
import Structure

enum AppDatabaseDirectory {
    /// Resolves the shared SQLite directory (same path as AgentService via `DerrickAppSupport`).
    static func resolve(applicationName: String) throws -> URL {
        try DerrickAppSupport.databaseDirectory(applicationName: applicationName)
    }
}
