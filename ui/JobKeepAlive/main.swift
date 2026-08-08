import Foundation
import DockerRunnerXPC
import ServiceContracts
import UserNotifications
import SQLite3
import AppKit

/// Login / keep-alive helper: holds an XPC connection to JobService so the scheduler
/// stays up for the user session. Does not run job steps itself.
/// Also polls `job_results` and posts user notifications when the UI is not running.
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
JobResultNotifier.shared.start()
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

// MARK: - Job result notifications (UI may be quit)

/// Polls shared SQLite `job_results` and posts UN notifications for unread rows.
/// Click opens the main `ui.app` which loads unread results into the modal.
final class JobResultNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = JobResultNotifier()

    private let defaultsKey = "notifiedJobResultIDs"
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            fputs(
                "[JobKeepAlive] notification auth granted=\(granted) err=\(error?.localizedDescription ?? "nil")\n",
                stderr
            )
        }
        let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: "JOB_RESULT",
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 10)
        t.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        t.resume()
        timer = t
        fputs("[JobKeepAlive] job result notifier started\n", stderr)
    }

    private func pollOnce() {
        // Skip if main UI is already frontmost (it handles modal itself).
        if isMainUIRunning() {
            return
        }
        let rows = loadUnreadJobResults()
        guard !rows.isEmpty else { return }
        lock.lock()
        var notified = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        lock.unlock()
        for row in rows {
            if notified.contains(row.id) { continue }
            postNotification(row)
            notified.insert(row.id)
        }
        lock.lock()
        // Cap remembered ids
        let trimmed = Array(notified.suffix(200))
        UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        lock.unlock()
    }

    private func isMainUIRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "derrick.ui"
        }
    }

    private struct ResultRow {
        let id: String
        let jobID: String
        let body: String
    }

    private func loadUnreadJobResults() -> [ResultRow] {
        guard let dbPath = sharedDatabasePath() else {
            fputs("[JobKeepAlive] job_results DB not found\n", stderr)
            return []
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            fputs("[JobKeepAlive] sqlite open failed: \(dbPath)\n", stderr)
            return []
        }
        defer { sqlite3_close(db) }
        // Table may not exist on older DBs
        let sql = """
        SELECT id, job_id, response_text FROM job_results
        WHERE read_at IS NULL
        ORDER BY created_at DESC LIMIT 10;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            fputs("[JobKeepAlive] job_results prepare failed (migration?)\n", stderr)
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [ResultRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c0 = sqlite3_column_text(stmt, 0),
                  let c1 = sqlite3_column_text(stmt, 1),
                  let c2 = sqlite3_column_text(stmt, 2) else { continue }
            out.append(
                ResultRow(
                    id: String(cString: c0),
                    jobID: String(cString: c1),
                    body: String(cString: c2)
                )
            )
        }
        if !out.isEmpty {
            fputs("[JobKeepAlive] unread job_results count=\(out.count)\n", stderr)
        }
        return out
    }

    private func sharedDatabasePath() -> String? {
        let groupID = "VUSK4B2YKQ.derrick.shared"
        let rel = "Library/Group Containers/\(groupID)/Library/Application Support/ui/derrick.sqlite3"
        // 1) Real user home (LaunchAgent / non-sandbox KeepAlive)
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
                .appendingPathComponent(rel).path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // 2) App group container API (works when group is entitled)
        if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            let path = base
                .appendingPathComponent("Library/Application Support/ui/derrick.sqlite3")
                .path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // 3) HOME env if not containerized
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.contains("/Containers/") {
            let path = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(rel).path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func postNotification(_ row: ResultRow) {
        let content = UNMutableNotificationContent()
        content.title = "Scheduled job finished"
        let preview = row.body.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = preview.count > 180 ? String(preview.prefix(177)) + "…" : preview
        content.sound = .default
        content.categoryIdentifier = "JOB_RESULT"
        content.userInfo = ["jobResultID": row.id, "jobID": row.jobID]

        let request = UNNotificationRequest(
            identifier: "job-result-\(row.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                fputs("[JobKeepAlive] notify failed: \(error.localizedDescription)\n", stderr)
            } else {
                fputs("[JobKeepAlive] notified jobResult=\(row.id)\n", stderr)
            }
        }
    }

    private func openMainApp() {
        // Prefer the host app next to this helper: …/ui.app/Contents/MacOS/JobKeepAlive
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // …/ui.app/Contents/MacOS/JobKeepAlive → …/ui.app
        let appURL = exe
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // ui.app
        if appURL.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    fputs("[JobKeepAlive] open app failed: \(error.localizedDescription)\n", stderr)
                }
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "derrick.ui") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        openMainApp()
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
