import Foundation

/// Shared app-support paths (UI, XPC services, JobKeepAlive use the same SQLite file).
///
/// Prefer the **App Group** container so processes that are not the sandboxed UI
/// (JobService, JobKeepAlive LaunchAgent, etc.) can open the same database.
/// Legacy host-container DB is migrated into the group on first use.
public enum DerrickAppSupport {
    public static let defaultApplicationName = "ui"
    /// Host app bundle id (must match PRODUCT_BUNDLE_IDENTIFIER of the UI target).
    public static let hostAppBundleIdentifier = "derrick.ui"
    /// Shared group for multi-process SQLite (must match entitlements on all targets that touch the DB).
    public static let applicationGroupIdentifier = "VUSK4B2YKQ.derrick.shared"

    public static func databaseDirectory(applicationName: String = defaultApplicationName) throws -> URL {
        let fm = FileManager.default
        let candidates = preferredDatabaseParentDirectories()
        guard let parent = candidates.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directoryURL = parent.appendingPathComponent(applicationName, isDirectory: true)
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        try migrateLegacyDatabaseIfNeeded(into: directoryURL)
        return directoryURL
    }

    /// Ordered: App Group Application Support, host app container, process Application Support.
    public static func preferredDatabaseParentDirectories() -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default

        if let groupRoot = fm.containerURL(forSecurityApplicationGroupIdentifier: applicationGroupIdentifier) {
            urls.append(
                groupRoot.appendingPathComponent("Library/Application Support", isDirectory: true)
            )
        }

        let home = fm.homeDirectoryForCurrentUser
        let containerSupport = home
            .appendingPathComponent(
                "Library/Containers/\(hostAppBundleIdentifier)/Data/Library/Application Support",
                isDirectory: true
            )
        urls.append(containerSupport)

        if let processSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            if processSupport.standardizedFileURL != containerSupport.standardizedFileURL {
                urls.append(processSupport)
            }
        }
        return urls
    }

    /// Copy `derrick.sqlite3` (+ WAL/SHM) from host container into the group directory when
    /// the destination is missing or clearly a smaller/empty placeholder.
    private static func migrateLegacyDatabaseIfNeeded(into directoryURL: URL) throws {
        let fm = FileManager.default
        let destDB = directoryURL.appendingPathComponent("derrick.sqlite3")

        let home = fm.homeDirectoryForCurrentUser
        let legacyDir = home
            .appendingPathComponent(
                "Library/Containers/\(hostAppBundleIdentifier)/Data/Library/Application Support/\(defaultApplicationName)",
                isDirectory: true
            )
        let legacyDB = legacyDir.appendingPathComponent("derrick.sqlite3")
        guard fm.fileExists(atPath: legacyDB.path) else { return }

        let legacySize = (try? fm.attributesOfItem(atPath: legacyDB.path)[.size] as? NSNumber)?.int64Value ?? 0
        let destSize = fm.fileExists(atPath: destDB.path)
            ? ((try? fm.attributesOfItem(atPath: destDB.path)[.size] as? NSNumber)?.int64Value ?? 0)
            : 0
        // Skip if dest already holds a full copy (same size or larger).
        if destSize >= legacySize, destSize > 0 { return }

        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        for name in ["derrick.sqlite3", "derrick.sqlite3-wal", "derrick.sqlite3-shm"] {
            let src = legacyDir.appendingPathComponent(name)
            let dst = directoryURL.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                fputs(
                    "[DerrickAppSupport] migrate copy failed \(name): \(error.localizedDescription)\n",
                    stderr
                )
            }
        }
        fputs(
            "[DerrickAppSupport] migrated DB from host container → \(directoryURL.path)\n",
            stderr
        )
    }

    /// Path fragment for the embedded Login Item daemon (`…/ui.app/Contents/Library/LoginItems/JobKeepAlive.app`).
    public static let loginItemDaemonPathMarker = "/Contents/Library/LoginItems/JobKeepAlive.app"

    /// True when this process is the launchd/SMAppService daemon nested under `ui.app`.
    public static func isEmbeddedLoginItemDaemon(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        bundleURL.standardizedFileURL.path.contains(loginItemDaemonPathMarker)
    }

    /// Resolve the host `derrick.ui` app bundle from an embedded or sibling JobKeepAlive layout.
    public static func hostUIApplicationURL(bundleURL: URL = Bundle.main.bundleURL) -> URL? {
        var dir = bundleURL.standardizedFileURL
        for _ in 0..<12 {
            if dir.pathExtension == "app",
               Bundle(url: dir)?.bundleIdentifier == hostAppBundleIdentifier {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // Xcode Debug layout: `Products/Debug/JobKeepAlive.app` beside `Products/Debug/ui.app`.
        let sibling = bundleURL.deletingLastPathComponent().appendingPathComponent("ui.app", isDirectory: true)
        if Bundle(url: sibling)?.bundleIdentifier == hostAppBundleIdentifier {
            return sibling
        }
        return nil
    }
}
