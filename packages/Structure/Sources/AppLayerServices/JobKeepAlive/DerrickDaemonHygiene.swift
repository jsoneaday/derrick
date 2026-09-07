import Foundation

/// Pure rules for deciding whether a running `JobKeepAlive` process should be evicted (UI-only enforcement).
public enum DerrickDaemonHygiene: Sendable {
    public enum EvictionReason: String, Sendable, Equatable {
        /// Not nested under the current host app / wrong bundle layout (e.g. stray `Products/Debug/JobKeepAlive.app`).
        case orphanPath
        /// Extra copy of the expected binary (Mach name / SQLite lock).
        case duplicate
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
        staleBuildTolerance _: TimeInterval = 1.0
    ) -> EvictionReason? {
        _ = processStartDate
        _ = expectedExecutableModificationDate
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
        lastAcceptedExecutableModificationDate _: Date?,
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
        return nil
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// True when a LaunchAgent `Program` / `ProgramArguments[0]` is not this host app's embedded daemon.
    /// After `PRODUCT_NAME` changes (`ui.app` → `Derrick.app`) launchd can stay on the old path.
    public static func isRegisteredDaemonProgramStale(
        registeredProgramPath: String?,
        expectedExecutablePath: String
    ) -> Bool {
        guard let registered = registeredProgramPath, !registered.isEmpty else { return true }
        return canonicalPath(registered) != canonicalPath(expectedExecutablePath)
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

    /// After eviction: (re)register when we do not have exactly one healthy process.
    /// A missing session launchd label is not enough to restart — SMAppService jobs
    /// use `application.derrick.ui.Daemon.<uuid>` and still run the helper.
    public static func shouldRestartDaemonAfterReconcile(
        evictedAny: Bool,
        hasHealthyExpectedDaemon: Bool,
        launchdJobLoaded: Bool = true,
        healthyExpectedDaemonCount: Int = 1
    ) -> Bool {
        if hasHealthyExpectedDaemon, healthyExpectedDaemonCount == 1 {
            return false
        }
        if !launchdJobLoaded { return true }
        if healthyExpectedDaemonCount != 1 { return true }
        return evictedAny || !hasHealthyExpectedDaemon
    }

    /// Extra processes of the expected binary steal the Mach service and lock SQLite.
    /// Keep the newest; evict the rest.
    public static func duplicateExpectedDaemonPIDsToEvict(
        expectedExecutablePath: String,
        processes: [(pid: Int32, executablePath: String, startDate: Date?)]
    ) -> [Int32] {
        let expected = canonicalPath(expectedExecutablePath)
        let matching = processes.filter { canonicalPath($0.executablePath) == expected }
        guard matching.count > 1 else { return [] }
        let ranked = matching.sorted { lhs, rhs in
            switch (lhs.startDate, rhs.startDate) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            return lhs.pid > rhs.pid
        }
        return ranked.dropFirst().map(\.pid)
    }

    /// SMAppService Login Item jobs are `application.derrick.ui.Daemon.<uuid>` and do
    /// not check in `MachServices`. Hand those off to `derrick.ui.Daemon.session`.
    public static func shouldHandoffSMAppSpawnToSessionAgent(xpcServiceName: String?) -> Bool {
        guard let name = xpcServiceName, !name.isEmpty else { return false }
        return name.hasPrefix("application.\(DerrickServiceID.daemon.rawValue).")
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
