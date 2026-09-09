import Foundation

public enum DerrickAppSupportError: Error, LocalizedError, Sendable {
    case sharedDatabaseUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .sharedDatabaseUnavailable(let message):
            return message
        }
    }
}

/// Shared app-support paths (UI, XPC services, JobKeepAlive use the same SQLite file).
///
/// Prefer the **App Group** container so processes that are not the sandboxed UI
/// (JobService, JobKeepAlive LaunchAgent, etc.) can open the same database.
/// Legacy host-container DB is migrated into the group on first use.
public enum DerrickAppSupport {
    /// Application Support subdirectory. Keep stable so existing SQLite is not split if PRODUCT_NAME changes.
    public static let defaultApplicationName = "ui"
    /// Dock / bundle file name (`Derrick.app`). Bundle id stays `derrick.ui`.
    public static let hostAppProductName = "Derrick"
    /// Host app bundle id (must match PRODUCT_BUNDLE_IDENTIFIER of the UI target).
    public static let hostAppBundleIdentifier = "derrick.ui"
    /// Shared group for multi-process SQLite (must match entitlements on all targets that touch the DB).
    public static let applicationGroupIdentifier = "VUSK4B2YKQ.derrick.shared"

    public static func databaseDirectory(applicationName: String = defaultApplicationName) throws -> URL {
        let fm = FileManager.default
        if let groupParent = appGroupApplicationSupportURL(),
           let directoryURL = try resolveWritableDatabaseDirectory(
               parent: groupParent,
               applicationName: applicationName,
               fileManager: fm
           ) {
            try migrateLegacyDatabaseIfNeeded(into: directoryURL)
            return directoryURL
        }

        if DerrickProcessRole.isDaemon {
            // Unsigned local builds cannot embed App Group entitlements. The UI falls back to
            // the host container; the unsandboxed daemon must open that same path.
            if let directoryURL = try resolveWritableDatabaseDirectory(
                parent: hostContainerApplicationSupportURL(),
                applicationName: applicationName,
                fileManager: fm
            ) {
                try migrateLegacyDatabaseIfNeeded(into: directoryURL)
                return directoryURL
            }
            throw DerrickAppSupportError.sharedDatabaseUnavailable(
                """
                The background service cannot open the shared database. This usually means JobKeepAlive was built without App Group entitlements.

                Quit Derrick, rebuild from Xcode with your development team enabled, then open Derrick again. If it still fails, remove Derrick from Login Items, then reopen the app.
                """
            )
        }

        let hostParent = hostContainerApplicationSupportURL()
        if let directoryURL = try resolveWritableDatabaseDirectory(
            parent: hostParent,
            applicationName: applicationName,
            fileManager: fm
        ) {
            try migrateLegacyDatabaseIfNeeded(into: directoryURL)
            return directoryURL
        }

        throw CocoaError(.fileNoSuchFile)
    }

    /// Singleton lock for `derrickd`. Lives outside the App Group so unsigned dev builds can still coordinate.
    public static func daemonSingletonLockURL() -> URL {
        let directory = homeApplicationSupportDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("derrickd.lock", isDirectory: false)
    }

    /// Ordered: App Group Application Support, host app container, process Application Support.
    public static func preferredDatabaseParentDirectories() -> [URL] {
        var urls: [URL] = []
        if let groupParent = appGroupApplicationSupportURL() {
            urls.append(groupParent)
        }
        urls.append(hostContainerApplicationSupportURL())
        let fm = FileManager.default
        if let processSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let host = hostContainerApplicationSupportURL()
            if processSupport.standardizedFileURL != host.standardizedFileURL {
                urls.append(processSupport)
            }
        }
        return urls
    }

    private static func appGroupApplicationSupportURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: applicationGroupIdentifier)?
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func hostContainerApplicationSupportURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(hostAppBundleIdentifier)/Data/Library/Application Support",
                isDirectory: true
            )
    }

    private static func homeApplicationSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Derrick", isDirectory: true)
    }

    private static func resolveWritableDatabaseDirectory(
        parent: URL,
        applicationName: String,
        fileManager: FileManager
    ) throws -> URL? {
        let directoryURL = parent.appendingPathComponent(applicationName, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard canWriteProbe(in: directoryURL, fileManager: fileManager) else {
            return nil
        }
        return directoryURL
    }

    private static func canWriteProbe(in directoryURL: URL, fileManager: FileManager) -> Bool {
        let probeURL = directoryURL.appendingPathComponent(".derrick-db-probe", isDirectory: false)
        do {
            try Data("ok".utf8).write(to: probeURL, options: .atomic)
            try fileManager.removeItem(at: probeURL)
            return true
        } catch {
            fputs(
                "[DerrickAppSupport] database probe failed \(directoryURL.path): \(error.localizedDescription)\n",
                stderr
            )
            return false
        }
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
        // Skip if dest already has a usable DB. Retrying a permission-denied copy on
        // every launch stalls "Opening local database…" and can clobber WAL.
        if destSize > 0 { return }

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

    /// Path fragment for the embedded Login Item daemon (`…/Derrick.app/Contents/Library/LoginItems/JobKeepAlive.app`).
    public static let loginItemDaemonPathMarker = "/Contents/Library/LoginItems/JobKeepAlive.app"

    /// LaunchAgent plist for `daemonSessionLaunchdLabel`. Kept out of `~/Library/LaunchAgents`
    /// so BTM does not treat it as the disabled legacy `derrick.ui.Daemon` item.
    public static func daemonSessionLaunchAgentPlistURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(
            "Library/Application Support/Derrick/derrick.ui.Daemon.session.plist",
            isDirectory: false
        )
    }

    /// True when this process is the launchd/SMAppService daemon nested under the host app.
    public static func isEmbeddedLoginItemDaemon(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        bundleURL.standardizedFileURL.path.contains(loginItemDaemonPathMarker)
    }

    /// Written when the UI finishes client bootstrap; used to verify launch does not hang.
    public static func uiBootstrapReadyMarkerURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: applicationGroupIdentifier)?
            .appendingPathComponent("ui-bootstrap-ready", isDirectory: false)
    }

    public static func writeUIBootstrapReadyMarker() {
        guard let url = uiBootstrapReadyMarkerURL() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "ready\n".write(to: url, atomically: true, encoding: .utf8)
    }

    public static func clearUIBootstrapReadyMarker() {
        guard let url = uiBootstrapReadyMarkerURL() else { return }
        try? FileManager.default.removeItem(at: url)
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
        // Xcode Debug layout: `Products/Debug/JobKeepAlive.app` beside `Products/Debug/Derrick.app`.
        let sibling = bundleURL.deletingLastPathComponent().appendingPathComponent(
            "\(hostAppProductName).app",
            isDirectory: true
        )
        if Bundle(url: sibling)?.bundleIdentifier == hostAppBundleIdentifier {
            return sibling
        }
        return nil
    }
}
