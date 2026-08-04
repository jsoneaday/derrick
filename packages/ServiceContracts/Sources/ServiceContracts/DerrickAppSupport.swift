import Foundation

/// Shared app-support paths (UI and XPC services use the same directory for SQLite).
///
/// The main app is sandboxed (`derrick.ui`), so its Application Support lives under
/// `Library/Containers/derrick.ui/...`. Embedded XPC services are often *not* sandboxed
/// and would otherwise resolve a different path and a different empty database
/// (policy deny-by-default). Always prefer the host app container when present.
public enum DerrickAppSupport {
    public static let defaultApplicationName = "ui"
    /// Host app bundle id (must match PRODUCT_BUNDLE_IDENTIFIER of the UI target).
    public static let hostAppBundleIdentifier = "derrick.ui"

    public static func databaseDirectory(applicationName: String = defaultApplicationName) throws -> URL {
        let fm = FileManager.default
        let candidates = preferredDatabaseParentDirectories()
        for parent in candidates {
            let directoryURL = parent.appendingPathComponent(applicationName, isDirectory: true)
            do {
                try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                // Prefer an existing shared DB when present so we do not create a parallel empty one.
                let dbFile = directoryURL.appendingPathComponent("derrick.sqlite3")
                if fm.fileExists(atPath: dbFile.path) {
                    return directoryURL
                }
            } catch {
                continue
            }
        }
        // Create in the highest-priority writable parent (host container when available).
        guard let parent = candidates.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directoryURL = parent.appendingPathComponent(applicationName, isDirectory: true)
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    /// Ordered: host app container Application Support, then process Application Support.
    public static func preferredDatabaseParentDirectories() -> [URL] {
        var urls: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let containerSupport = home
            .appendingPathComponent("Library/Containers/\(hostAppBundleIdentifier)/Data/Library/Application Support", isDirectory: true)
        urls.append(containerSupport)
        if let processSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Avoid duplicating when process is already the sandboxed app (same path).
            if processSupport.standardizedFileURL != containerSupport.standardizedFileURL {
                urls.append(processSupport)
            }
        }
        return urls
    }
}
