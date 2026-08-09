import Darwin
import Foundation
import ServiceContracts

/// UI-only: evict orphan or stale `JobKeepAlive` processes before `ensureDaemon`.
public enum DaemonProcessHygiene {
    private static let terminateGraceNanoseconds: UInt64 = 500_000_000
    private static let postKillWaitNanoseconds: UInt64 = 400_000_000

    /// Kill stray daemons and stale embedded builds, then kickstart launchd when needed.
    public static func reconcile(hostAppBundle: URL = Bundle.main.bundleURL) async {
        guard !DerrickProcessRole.isDaemon else { return }

        let paths = JobServiceLoginAgent.preflightPaths()
        let expectedExe = paths.executable
        guard FileManager.default.isExecutableFile(atPath: expectedExe.path) else {
            fputs(
                "[DaemonHygiene] skip — embedded daemon missing at \(expectedExe.path)\n",
                stderr
            )
            return
        }

        let expectedMtime = modificationDate(expectedExe)
        let processes = listJobKeepAliveProcesses()
        guard !processes.isEmpty else {
            fputs(
                "[DaemonHygiene] reconcile ok — no JobKeepAlive processes (expected=\(expectedExe.path))\n",
                stderr
            )
            return
        }

        fputs(
            "[DaemonHygiene] reconcile found \(processes.count) JobKeepAlive process(es) expected=\(expectedExe.path)\n",
            stderr
        )

        var evictedExpectedDaemon = false
        for process in processes {
            guard let reason = DerrickDaemonHygiene.evictionReason(
                executablePath: process.executablePath,
                processStartDate: process.startDate,
                hostAppBundlePath: hostAppBundle.path,
                expectedExecutablePath: expectedExe.path,
                expectedExecutableModificationDate: expectedMtime
            ) else {
                continue
            }
            if DerrickDaemonHygiene.canonicalPath(process.executablePath)
                == DerrickDaemonHygiene.canonicalPath(expectedExe.path) {
                evictedExpectedDaemon = true
            }
            terminate(
                pid: process.pid,
                reason: reason,
                path: process.executablePath
            )
        }

        if evictedExpectedDaemon {
            try? await Task.sleep(nanoseconds: postKillWaitNanoseconds)
            JobServiceLoginAgent.kickstartRegisteredDaemon()
        }
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
            guard URL(fileURLWithPath: path).lastPathComponent == JobServiceLoginAgent.executableName else {
                return nil
            }
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
        process.arguments = ["-x", JobServiceLoginAgent.executableName]
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
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
