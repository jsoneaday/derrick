import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Login / keep-alive helper: holds an XPC connection to JobService so the scheduler
/// stays up for the user session. Does not run job steps itself.
///
/// Usage:
///   JobKeepAlive                 — run keep-alive loop (default; used by launchd)
///   JobKeepAlive --install-launchd — write ~/Library/LaunchAgents plist + bootstrap, then exit
///   JobKeepAlive --install-and-run  — install then run keep-alive

let args = Set(CommandLine.arguments.dropFirst())
let installOnly = args.contains("--install-launchd")
let installAndRun = args.contains("--install-and-run")

if installOnly || installAndRun {
    do {
        try LaunchAgentInstaller.install(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]))
        fputs("[JobKeepAlive] launchd install ok\n", stderr)
    } catch {
        fputs("[JobKeepAlive] launchd install failed: \(error.localizedDescription)\n", stderr)
        if installOnly { exit(1) }
    }
    if installOnly { exit(0) }
}

fputs("[JobKeepAlive] starting pid=\(ProcessInfo.processInfo.processIdentifier)\n", stderr)
KeepAliveRunner().runForever()

// MARK: - Install user LaunchAgent (absolute path; reliable vs flaky SM-only jobs)

enum LaunchAgentInstaller {
    static let label = "derrick.ui.JobKeepAlive"
    static let plistName = "derrick.ui.JobKeepAlive.plist"

    static func install(executableURL: URL) throws {
        let exe = executableURL.resolvingSymlinksInPath().path
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            throw InstallError.notExecutable(exe)
        }

        // Prefer passwd home — `FileManager.homeDirectoryForCurrentUser` is the *container*
        // home when launched from the sandboxed UI, and launchd will not bootstrap from there.
        let home = realUserHomeDirectory()
        let agentsDir = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let dest = agentsDir.appendingPathComponent(plistName)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(exe)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>10</integer>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>derrick.ui</string>
            </array>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """
        try plist.write(to: dest, atomically: true, encoding: .utf8)
        fputs("[JobKeepAlive] wrote \(dest.path)\n", stderr)

        let uid = getuid()
        let domainLabel = "gui/\(uid)/\(label)"

        // Idempotent load: bootout (ignore miss), bootstrap (ignore "already loaded"), then kickstart.
        _ = runLaunchctlAllowFail(["bootout", domainLabel])
        let boot = runLaunchctlAllowFail(["bootstrap", "gui/\(uid)", dest.path])
        if boot.status != 0 {
            // Error 5 / I/O often means already bootstrapped or transient; accept if print works.
            if isLoaded(domainLabel: domainLabel) {
                fputs(
                    "[JobKeepAlive] bootstrap returned \(boot.status) but job already loaded; continuing\n",
                    stderr
                )
            } else {
                throw InstallError.launchctlFailed(
                    "launchctl bootstrap → \(boot.status) \(boot.output)"
                )
            }
        }
        _ = runLaunchctlAllowFail(["enable", domainLabel])
        let kick = runLaunchctlAllowFail(["kickstart", "-k", domainLabel])
        if kick.status != 0, !isLoaded(domainLabel: domainLabel) {
            throw InstallError.launchctlFailed(
                "launchctl kickstart → \(kick.status) \(kick.output)"
            )
        }
        if !isLoaded(domainLabel: domainLabel) {
            throw InstallError.launchctlFailed("job not loaded after install: \(domainLabel)")
        }
    }

    private static func isLoaded(domainLabel: String) -> Bool {
        runLaunchctlAllowFail(["print", domainLabel]).status == 0
    }

    /// Runs launchctl; never throws (caller decides).
    private static func runLaunchctlAllowFail(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (status: -1, output: error.localizedDescription)
        }
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (status: process.terminationStatus, output: (e + o).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Real macOS user home (e.g. /Users/name), not the app-sandbox container home.
    private static func realUserHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.contains("/Containers/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    enum InstallError: Error, LocalizedError {
        case notExecutable(String)
        case launchctlFailed(String)
        var errorDescription: String? {
            switch self {
            case .notExecutable(let p): return "Not executable: \(p)"
            case .launchctlFailed(let m): return m
            }
        }
    }
}

// MARK: - Keep-alive loop

final class KeepAliveRunner: @unchecked Sendable {
    private let serviceName = DerrickServiceID.job.xpcServiceName
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let intervalNanoseconds: UInt64 = 15_000_000_000 // 15s health ping

    func runForever() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            while !Task.isCancelled {
                do {
                    try await ensureConnectedAndHealthy()
                } catch {
                    fputs("[JobKeepAlive] ensure failed: \(error.localizedDescription)\n", stderr)
                    invalidate()
                }
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
            sem.signal()
        }
        sem.wait()
    }

    private func ensureConnectedAndHealthy() async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.bootstrap { data in
                do {
                    let boot = try JobServiceXPCCodec.decodeBootstrap(data as Data)
                    if boot.ok {
                        cont.resume()
                    } else {
                        cont.resume(throwing: KeepAliveError.bootstrapFailed(boot.message))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        let report: ServiceHealthReport = try await withCheckedThrowingContinuation { cont in
            proxy.health { data in
                do {
                    cont.resume(returning: try JobServiceXPCCodec.decodeHealth(data as Data))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        fputs(
            "[JobKeepAlive] JobService ok status=\(report.status.rawValue) pid=\(report.pid)\n",
            stderr
        )
    }

    private func remoteProxy() throws -> JobServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(serviceName: serviceName)
            conn.remoteObjectInterface = NSXPCInterface(with: JobServiceXPC.self)
            do {
                try XPCPeerAuthentication.apply(
                    requirement: XPCPeerAuthentication.requirementString(
                        allowedPeerIdentifiers: [DerrickServiceID.job.rawValue]
                    ),
                    to: conn
                )
            } catch {
                fputs("[JobKeepAlive] code-sign soft-fail: \(error.localizedDescription)\n", stderr)
            }
            conn.interruptionHandler = { [weak self] in
                fputs("[JobKeepAlive] connection interrupted\n", stderr)
                self?.invalidate()
            }
            conn.invalidationHandler = { [weak self] in
                fputs("[JobKeepAlive] connection invalidated\n", stderr)
                self?.invalidate()
            }
            conn.resume()
            connection = conn
            fputs("[JobKeepAlive] connected serviceName=\(serviceName)\n", stderr)
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("[JobKeepAlive] proxy error: \(error.localizedDescription)\n", stderr)
            self?.invalidate()
        }) as? JobServiceXPC else {
            throw KeepAliveError.unavailable
        }
        return proxy
    }

    private func invalidate() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }
}

enum KeepAliveError: Error, LocalizedError {
    case unavailable
    case bootstrapFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "JobService unavailable"
        case .bootstrapFailed(let m): return "JobService bootstrap failed: \(m)"
        }
    }
}
