import Darwin
import Foundation
import ServiceContracts

/// UI-only: evict orphan or stale `JobKeepAlive` processes before `ensureDaemon`.
public enum DaemonProcessHygiene {
    private static let terminateGraceNanoseconds: UInt64 = 500_000_000
    private static let postKillWaitNanoseconds: UInt64 = 400_000_000
    private static let acceptedMtimeDefaultsKey = "derrick.daemon.acceptedEmbeddedMtime"

    /// After XPC health: ask a stale connected daemon to exit so launchd KeepAlive re-execs.
    /// Sandboxed `kill(pid, 0)` cannot see JobKeepAlive — liveness is XPC health only.
    /// Returns true when the caller should drop its connection and reconnect.
    @discardableResult
    public static func evictIfStaleGuestRuntime(_ health: ServiceHealthReport) async -> Bool {
        guard isStaleConnectedDaemon(health) else {
            debugLog(
                "[DaemonHygiene] connected pid=\(health.pid) guestRuntime=\(health.guestRuntimeImage ?? "?") fingerprint=\(health.executableFingerprint ?? "?")"
            )
            return false
        }
        debugLog(
            "[DaemonHygiene] stale connected daemon pid=\(health.pid) reportedRuntime=\(health.guestRuntimeImage ?? "none") reportedFP=\(health.executableFingerprint ?? "none") expectedFP=\(expectedFingerprint() ?? "none") — retiring"
        )
        fputs(
            "[DaemonHygiene] stale connected daemon pid=\(health.pid) reportedRuntime=\(health.guestRuntimeImage ?? "none") reportedFP=\(health.executableFingerprint ?? "none")\n",
            stderr
        )
        // Pre-identity daemons have no `retire` selector. Sandboxed kill() cannot
        // confirm death — if XPC retire is missing or health still shows this pid, bootout.
        let retired: Bool
        if health.executableFingerprint == nil {
            retired = false
        } else {
            retired = await requestRetirementOverXPC()
            try? await Task.sleep(nanoseconds: postKillWaitNanoseconds)
        }
        let stillStale = retired ? await stillSameStaleProcess(pid: health.pid) : true
        if stillStale {
            fputs(
                "[DaemonHygiene] retire xpc=\(retired) still pid=\(health.pid) — bootout+reload\n",
                stderr
            )
            JobServiceLoginAgent.bootoutRegisteredDaemon()
            await MainActor.run {
                try? JobServiceLoginAgent.ensureRegistered()
            }
            JobServiceLoginAgent.reloadRegisteredDaemon()
            await waitUntilReplacementDaemon(replacing: health.pid)
        } else {
            debugLog("[DaemonHygiene] retired pid=\(health.pid) xpc=\(retired) — KeepAlive will re-exec")
        }
        return true
    }

    public static func isStaleConnectedDaemon(_ health: ServiceHealthReport) -> Bool {
        DerrickDaemonHygiene.shouldRetireConnectedDaemon(
            reportedFingerprint: health.executableFingerprint,
            expectedFingerprint: expectedFingerprint(),
            reportedGuestRuntime: health.guestRuntimeImage,
            expectedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage
        )
    }

    private static func expectedFingerprint() -> String? {
        DerrickDaemonBinaryIdentity.snapshot(
            atPath: JobServiceLoginAgent.preflightPaths().executable.path
        )?.fingerprint
    }

    private static func stillSameStaleProcess(pid: Int32) async -> Bool {
        guard let probe = await probeDaemonHealth() else {
            return false
        }
        return probe.pid == pid && isStaleConnectedDaemon(probe)
    }

    private static func waitUntilReplacementDaemon(replacing pid: Int32) async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let probe = await probeDaemonHealth() else { continue }
            if probe.pid != pid && !isStaleConnectedDaemon(probe) {
                debugLog("[DaemonHygiene] replacement daemon pid=\(probe.pid) fingerprint=\(probe.executableFingerprint ?? "?")")
                return
            }
        }
        fputs("[DaemonHygiene] replacement daemon not confirmed after reload\n", stderr)
    }

    private static func requestRetirementOverXPC() async -> Bool {
        await invokeDaemon { proxy, once in
            proxy.retire { _ in
                once.finish(true)
            }
        }
    }

    private static func probeDaemonHealth() async -> ServiceHealthReport? {
        await withCheckedContinuation { (cont: CheckedContinuation<ServiceHealthReport?, Never>) in
            let box = OptionalResume(cont)
            nonisolated(unsafe) let conn = NSXPCConnection(machServiceName: DerrickServiceID.daemon.machServiceName)
            conn.remoteObjectInterface = NSXPCInterface(with: DerrickDaemonXPC.self)
            conn.invalidationHandler = { box.finish(nil) }
            conn.resume()
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                fputs("[DaemonHygiene] health probe error: \(error.localizedDescription)\n", stderr)
                box.finish(nil)
            }) as? DerrickDaemonXPC else {
                conn.invalidate()
                box.finish(nil)
                return
            }
            proxy.health { data in
                let report = try? DerrickDaemonXPCCodec.decodeHealth(data as Data)
                box.finish(report)
                conn.invalidate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                box.finish(nil)
                conn.invalidate()
            }
        }
    }

    private static func invokeDaemon(_ body: (DerrickDaemonXPC, OnceResume) -> Void) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OnceResume(cont)
            nonisolated(unsafe) let conn = NSXPCConnection(machServiceName: DerrickServiceID.daemon.machServiceName)
            conn.remoteObjectInterface = NSXPCInterface(with: DerrickDaemonXPC.self)
            conn.resume()
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                fputs("[DaemonHygiene] retire proxy error: \(error.localizedDescription)\n", stderr)
                once.finish(false)
            }) as? DerrickDaemonXPC else {
                conn.invalidate()
                once.finish(false)
                return
            }
            body(proxy, once)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                once.finish(false)
                conn.invalidate()
            }
        }
    }

    /// Kill stray daemons and stale embedded builds, then kickstart launchd when needed.
    @discardableResult
    public static func reconcile(hostAppBundle: URL = Bundle.main.bundleURL) async -> Bool {
        guard !DerrickProcessRole.isDaemon else { return true }

        let paths = JobServiceLoginAgent.preflightPaths()
        let expectedExe = paths.executable
        guard FileManager.default.isExecutableFile(atPath: expectedExe.path) else {
            debugLog("[DaemonHygiene] skip — embedded daemon missing at \(expectedExe.path)")
            fputs(
                "[DaemonHygiene] skip — embedded daemon missing at \(expectedExe.path)\n",
                stderr
            )
            return false
        }

        let expectedMtime = modificationDate(expectedExe)
        let hostPath = hostAppBundle.path
        let expectedPath = expectedExe.path
        let lastAcceptedMtime: Date? = {
            let raw = UserDefaults.standard.double(forKey: acceptedMtimeDefaultsKey)
            guard raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw)
        }()

        let processes = listJobKeepAliveProcesses()
        if processes.isEmpty {
            debugLog("[DaemonHygiene] reconcile ok — no JobKeepAlive processes")
            fputs(
                "[DaemonHygiene] reconcile ok — no JobKeepAlive processes (expected=\(expectedPath))\n",
                stderr
            )
            return await restartDaemonIfNeeded(
                evictedAny: false,
                hostPath: hostPath,
                expectedPath: expectedPath,
                expectedMtime: expectedMtime
            )
        }

        debugLog("[DaemonHygiene] reconcile found \(processes.count) JobKeepAlive process(es)")
        fputs(
            "[DaemonHygiene] reconcile found \(processes.count) JobKeepAlive process(es) expected=\(expectedPath)\n",
            stderr
        )

        var evictedAny = false
        for process in processes {
            let startDesc = process.startDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
            guard let reason = DerrickDaemonHygiene.evictionReasonUsingAcceptedBinaryMtime(
                executablePath: process.executablePath,
                processStartDate: process.startDate,
                hostAppBundlePath: hostPath,
                expectedExecutablePath: expectedPath,
                expectedExecutableModificationDate: expectedMtime,
                lastAcceptedExecutableModificationDate: lastAcceptedMtime
            ) else {
                debugLog("[DaemonHygiene] keep pid=\(process.pid) start=\(startDesc)")
                continue
            }
            evictedAny = true
            debugLog("[DaemonHygiene] evict pid=\(process.pid) reason=\(reason.rawValue) start=\(startDesc)")
            terminate(
                pid: process.pid,
                reason: reason,
                path: process.executablePath
            )
        }

        let hasHealthy = listJobKeepAliveProcesses().contains { process in
            DerrickDaemonHygiene.evictionReasonUsingAcceptedBinaryMtime(
                executablePath: process.executablePath,
                processStartDate: process.startDate,
                hostAppBundlePath: hostPath,
                expectedExecutablePath: expectedPath,
                expectedExecutableModificationDate: expectedMtime,
                lastAcceptedExecutableModificationDate: lastAcceptedMtime
            ) == nil
                && DerrickDaemonHygiene.canonicalPath(process.executablePath)
                    == DerrickDaemonHygiene.canonicalPath(expectedPath)
        }

        let registrationSucceeded = await restartDaemonIfNeeded(
            evictedAny: evictedAny,
            hasHealthyExpectedDaemon: hasHealthy,
            hostPath: hostPath,
            expectedPath: expectedPath,
            expectedMtime: expectedMtime
        )

        if let expectedMtime,
           listJobKeepAliveProcesses().contains(where: {
               DerrickDaemonHygiene.canonicalPath($0.executablePath)
                   == DerrickDaemonHygiene.canonicalPath(expectedPath)
           }) {
            UserDefaults.standard.set(expectedMtime.timeIntervalSince1970, forKey: acceptedMtimeDefaultsKey)
        }
        return registrationSucceeded
    }

    @discardableResult
    private static func restartDaemonIfNeeded(
        evictedAny: Bool,
        hasHealthyExpectedDaemon: Bool = false,
        hostPath: String = "",
        expectedPath: String = "",
        expectedMtime: Date? = nil
    ) async -> Bool {
        guard DerrickDaemonHygiene.shouldRestartDaemonAfterReconcile(
            evictedAny: evictedAny,
            hasHealthyExpectedDaemon: hasHealthyExpectedDaemon
        ) else {
            fputs("[DaemonHygiene] expected daemon healthy — skip register/kickstart\n", stderr)
            return true
        }
        fputs(
            "[DaemonHygiene] register+kickstart evicted=\(evictedAny) healthy=\(hasHealthyExpectedDaemon)\n",
            stderr
        )
        let registered = await MainActor.run {
            do {
                let result = try JobServiceLoginAgent.ensureRegistered()
                guard result.isRunningOrEnabled else {
                    fputs(
                        "[DaemonHygiene] daemon registration requires user action: \(result.detail)\n",
                        stderr
                    )
                    return false
                }
                return true
            } catch {
                fputs(
                    "[DaemonHygiene] daemon registration failed: \(error.localizedDescription)\n",
                    stderr
                )
                return false
            }
        }
        guard registered else { return false }
        try? await Task.sleep(nanoseconds: postKillWaitNanoseconds)
        JobServiceLoginAgent.reloadRegisteredDaemon()
        debugLog("[DaemonHygiene] reload requested after evicted=\(evictedAny) healthy=\(hasHealthyExpectedDaemon)")
        return true
    }

    // MARK: - Process scan

    private struct RunningDaemon {
        let pid: pid_t
        let executablePath: String
        let startDate: Date?
    }

    private static func listJobKeepAliveProcesses() -> [RunningDaemon] {
        pgrepPIDs().compactMap { pid in
            guard let path = executablePath(forPID: pid) else { return nil }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let looksLikeDaemon = name == JobServiceLoginAgent.executableName
                || path.contains(DerrickAppSupport.loginItemDaemonPathMarker)
                || path.contains("/JobKeepAlive.app/")
            guard looksLikeDaemon else { return nil }
            return RunningDaemon(
                pid: pid,
                executablePath: path,
                startDate: processStartDate(pid: pid)
            )
        }
    }

    private static func pgrepPIDs() -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "JobKeepAlive"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fputs("[DaemonHygiene] pgrep failed: \(error.localizedDescription)\n", stderr)
            return []
        }
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return []
        }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public static func debugExecutablePath(pid: Int32) -> String? {
        executablePath(forPID: pid)
    }

    private static func executablePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processStartDate(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return nil }
        let seconds = TimeInterval(info.pbi_start_tvsec)
        let micros = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds + micros)
    }

    // MARK: - Terminate

    private static func terminate(pid: pid_t, reason: DerrickDaemonHygiene.EvictionReason, path: String) {
        fputs(
            "[DaemonHygiene] evict pid=\(pid) reason=\(reason.rawValue) path=\(path)\n",
            stderr
        )
        kill(pid, SIGTERM)
        Thread.sleep(forTimeInterval: TimeInterval(terminateGraceNanoseconds) / 1_000_000_000)
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            fputs("[DaemonHygiene] sigkill pid=\(pid)\n", stderr)
        }
        if kill(pid, 0) == 0 {
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/bin/kill")
            killer.arguments = ["-9", "\(pid)"]
            killer.standardError = Pipe()
            killer.standardOutput = Pipe()
            try? killer.run()
            killer.waitUntilExit()
            fputs("[DaemonHygiene] /bin/kill -9 pid=\(pid) status=\(killer.terminationStatus)\n", stderr)
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

private final class OptionalResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ServiceHealthReport?, Never>?

    init(_ continuation: CheckedContinuation<ServiceHealthReport?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: ServiceHealthReport?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
