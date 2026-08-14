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
        // Binary on disk is newer than process start → rebuild while daemon kept running.
        if let mtime = expectedExecutableModificationDate,
           let start = processStartDate,
           mtime.timeIntervalSince(start) > staleBuildTolerance {
            return .staleBuild
        }
        return nil
    }

    /// When process start time is unavailable (common under App Sandbox), compare the on-disk
    /// binary mtime to the mtime last accepted by a successful UI reconcile.
    public static func evictionReasonUsingAcceptedBinaryMtime(
        executablePath: String,
        processStartDate: Date?,
        hostAppBundlePath: String,
        expectedExecutablePath: String,
        expectedExecutableModificationDate: Date?,
        lastAcceptedExecutableModificationDate: Date?,
        staleBuildTolerance: TimeInterval = 1.0
    ) -> EvictionReason? {
        if let reason = evictionReason(
            executablePath: executablePath,
            processStartDate: processStartDate,
            hostAppBundlePath: hostAppBundlePath,
            expectedExecutablePath: expectedExecutablePath,
            expectedExecutableModificationDate: expectedExecutableModificationDate,
            staleBuildTolerance: staleBuildTolerance
        ) {
            return reason
        }
        guard processStartDate == nil,
              let expected = expectedExecutableModificationDate
        else {
            return nil
        }
        guard let accepted = lastAcceptedExecutableModificationDate else {
            // First observe with unknown start — accept current binary; next rebuild will differ.
            return nil
        }
        if abs(expected.timeIntervalSince(accepted)) > staleBuildTolerance {
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

    /// Connected daemon should exit (KeepAlive re-execs) when guest runtime or binary identity differs.
    /// A missing reported fingerprint is stale (pre-identity daemon). A missing expected fingerprint
    /// is not — the UI could not stat its embedded binary.
    public static func shouldRetireConnectedDaemon(
        reportedFingerprint: String?,
        expectedFingerprint: String?,
        reportedGuestRuntime: String?,
        expectedGuestRuntime: String
    ) -> Bool {
        if reportedGuestRuntime != expectedGuestRuntime {
            return true
        }
        guard let expectedFingerprint else { return false }
        guard let reportedFingerprint else { return true }
        return reportedFingerprint != expectedFingerprint
    }
}
