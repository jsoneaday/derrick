import Foundation

/// Pure rules for deciding whether a running `JobKeepAlive` process should be evicted (UI-only enforcement).
public enum DerrickDaemonHygiene: Sendable {
    public enum EvictionReason: String, Sendable, Equatable {
        /// Not nested under the current host app / wrong bundle layout (e.g. stray `Products/Debug/JobKeepAlive.app`).
        case orphanPath
        /// Embedded daemon binary was rebuilt after this process started.
        case staleBuild
    }

    /// Returns a reason to evict, or nil when the process matches the current host app build.
    public static func evictionReason(
        executablePath: String,
        processStartDate: Date?,
        hostAppBundlePath: String,
        expectedExecutablePath: String,
        expectedExecutableModificationDate: Date?,
        staleBuildTolerance: TimeInterval = 1.0
    ) -> EvictionReason? {
        let exe = canonicalPath(executablePath)
        let host = canonicalPath(hostAppBundlePath)
        let expected = canonicalPath(expectedExecutablePath)

        if !exe.contains(DerrickAppSupport.loginItemDaemonPathMarker) {
            return .orphanPath
        }
        if !exe.hasPrefix(host) {
            return .orphanPath
        }
        if exe != expected {
            return .orphanPath
        }
        if let mtime = expectedExecutableModificationDate,
           let start = processStartDate,
           mtime.timeIntervalSince(start) > staleBuildTolerance {
            return .staleBuild
        }
        return nil
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// True when a running process matches the current host build and should be kept.
    public static func isHealthyExpectedDaemon(
        executablePath: String,
        processStartDate: Date?,
        hostAppBundlePath: String,
        expectedExecutablePath: String,
        expectedExecutableModificationDate: Date?
    ) -> Bool {
        canonicalPath(executablePath) == canonicalPath(expectedExecutablePath)
            && evictionReason(
                executablePath: executablePath,
                processStartDate: processStartDate,
                hostAppBundlePath: hostAppBundlePath,
                expectedExecutablePath: expectedExecutablePath,
                expectedExecutableModificationDate: expectedExecutableModificationDate
            ) == nil
    }

    /// After eviction pass: (re)register and kickstart when anything was removed or nothing healthy remains.
    public static func shouldRestartDaemonAfterReconcile(
        evictedAny: Bool,
        hasHealthyExpectedDaemon: Bool
    ) -> Bool {
        evictedAny || !hasHealthyExpectedDaemon
    }
}
