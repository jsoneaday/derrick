import AppKit
import DerrickBackend
import DockerRunnerXPC
import Foundation
import ServiceContracts

/// Headless Derrick backend (`derrick.ui.Daemon`) — LSUIElement app launched by launchd.
///
/// Must be an application bundle (not a bare tool) so UserNotifications TCC works.
///
/// Usage:
///   JobKeepAlive                 — run forever (launchd)
///   JobKeepAlive --install-launchd — write LaunchAgent + bootstrap, then exit
///   JobKeepAlive --install-and-run — install then run

DerrickProcessRole.isDaemon = true
DaemonRuntime.onBootstrapModules = {
    await DaemonModuleBootstrap.startAllModules()
}

let args = Set(CommandLine.arguments.dropFirst())
let installOnly = args.contains("--install-launchd")
let installAndRun = args.contains("--install-and-run")
let testNotify = args.contains("--test-notify")

if installOnly || installAndRun {
    do {
        try DaemonLaunchAgentInstaller.install(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]))
        fputs("[derrickd] launchd install ok\n", stderr)
    } catch {
        fputs("[derrickd] launchd install failed: \(error.localizedDescription)\n", stderr)
        if installOnly { exit(1) }
    }
    if installOnly { exit(0) }
}

// Orphan `Products/Debug/JobKeepAlive.app` shares the DB and steals scheduled jobs but
// cannot resolve ui.app Resources (.env) — refuse to run outside LoginItems.
if !installAndRun && !testNotify && !DerrickAppSupport.isEmbeddedLoginItemDaemon() {
    fputs(
        "[derrickd] FATAL: refusing orphan JobKeepAlive at \(Bundle.main.bundleURL.path)\n",
        stderr
    )
    fputs(
        "[derrickd] Only ui.app/Contents/Library/LoginItems/JobKeepAlive.app should run the daemon.\n",
        stderr
    )
    fputs(
        "[derrickd] Kill stray copies: pkill -f 'Products/Debug/JobKeepAlive.app'\n",
        stderr
    )
    exit(78)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

NotificationSender.postsLocally = true
DaemonNotificationCenterDelegate.shared.install()

if testNotify {
    fputs("[derrickd] --test-notify\n", stderr)
    Task {
        let resultID = CommandLine.arguments
            .drop(while: { $0 != "--test-notify" })
            .dropFirst()
            .first(where: { !$0.hasPrefix("--") })
            ?? "test"
        let short = String(resultID.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
        let req = UserNotificationRequest(
            id: "derrick.job-result.\(resultID)",
            kind: .jobResult,
            title: "Derrick · Job finished",
            body: "Tap to view the result panel.",
            subtitle: "Result \(short)",
            timeSensitive: true,
            userInfo: [
                UserNotificationUserInfoKey.kind.rawValue: UserNotificationKind.jobResult.rawValue,
                UserNotificationUserInfoKey.jobResultID.rawValue: resultID
            ]
        )
        do {
            try await NotificationSender.post(req)
            fputs("[derrickd] --test-notify ok id=\(resultID)\n", stderr)
        } catch {
            fputs("[derrickd] --test-notify failed: \(error.localizedDescription)\n", stderr)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        exit(0)
    }
    app.run()
}

fputs(
    "[derrickd] starting pid=\(ProcessInfo.processInfo.processIdentifier) mach=\(DerrickServiceID.daemon.machServiceName)\n",
    stderr
)
DaemonSelfRetirement.install()

let listenerDelegate = DaemonUnifiedListenerDelegate()
let listener = NSXPCListener(machServiceName: DerrickServiceID.daemon.machServiceName)
listener.delegate = listenerDelegate
listener.resume()

Task {
    do {
        _ = try await DaemonRuntime.shared.bootstrap()
    } catch {
        fputs("[derrickd] bootstrap failed: \(error.localizedDescription)\n", stderr)
    }
}

app.run()

// MARK: - LaunchAgent install

enum DaemonLaunchAgentInstaller {
    static let label = DerrickServiceID.daemon.rawValue
    static let plistName = "\(label).plist"

    static func install(executableURL: URL) throws {
        let exe = executableURL.resolvingSymlinksInPath().path
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            throw InstallError.notExecutable(exe)
        }

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
            <key>MachServices</key>
            <dict>
                <key>\(DerrickServiceID.daemon.machServiceName)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>2</integer>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>\(DerrickServiceID.ui.rawValue)</string>
            </array>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(home.path)/Library/Logs/derrick.ui.Daemon.out.log</string>
            <key>StandardErrorPath</key>
            <string>\(home.path)/Library/Logs/derrick.ui.Daemon.err.log</string>
        </dict>
        </plist>
        """
        try plist.write(to: dest, atomically: true, encoding: .utf8)
        fputs("[derrickd] wrote \(dest.path)\n", stderr)
        stripQuarantine(at: dest)
        stripQuarantine(at: URL(fileURLWithPath: exe))

        let uid = getuid()
        let domainLabel = "gui/\(uid)/\(label)"
        _ = runLaunchctlAllowFail(["bootout", "gui/\(uid)/\(DerrickServiceID.jobKeepAlive.rawValue)"], timeoutSeconds: 3)
        _ = runLaunchctlAllowFail(["bootout", domainLabel], timeoutSeconds: 3)
        let boot = runLaunchctlAllowFail(["bootstrap", "gui/\(uid)", dest.path], timeoutSeconds: 5)
        if boot.status != 0 {
            if isLoaded(domainLabel: domainLabel) {
                fputs("[derrickd] bootstrap \(boot.status) but job loaded — continuing\n", stderr)
            } else if boot.status == 5 {
                throw InstallError.launchctlFailed(
                    "launchctl bootstrap → 5 (I/O). Prefer SMAppService; or run from Terminal: \(exe) --install-launchd"
                )
            } else {
                throw InstallError.launchctlFailed("launchctl bootstrap → \(boot.status) \(boot.output)")
            }
        }
        _ = runLaunchctlAllowFail(["enable", domainLabel], timeoutSeconds: 3)
        let kick = runLaunchctlAllowFail(["kickstart", "-k", domainLabel], timeoutSeconds: 12)
        if kick.status != 0 {
            fputs("[derrickd] kickstart status=\(kick.status) \(kick.output)\n", stderr)
        }
        Thread.sleep(forTimeInterval: 0.4)
        if !isLoaded(domainLabel: domainLabel) {
            throw InstallError.launchctlFailed("job not loaded after install: \(domainLabel)")
        }
    }

    private static func isLoaded(domainLabel: String) -> Bool {
        runLaunchctlAllowFail(["print", domainLabel], timeoutSeconds: 3).status == 0
    }

    private static func runLaunchctlAllowFail(
        _ arguments: [String],
        timeoutSeconds: TimeInterval = 15
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        do {
            try process.run()
        } catch {
            return (status: -1, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return (
                status: -2,
                output: "timed out after \(Int(timeoutSeconds))s: launchctl \(arguments.joined(separator: " "))"
            )
        }

        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (status: process.terminationStatus, output: (e + o).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func stripQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                fputs(
                    "[derrickd] xattr skip (status=\(process.terminationStatus)) \(url.lastPathComponent)\n",
                    stderr
                )
            }
        } catch {
            fputs("[derrickd] xattr unavailable: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func realUserHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
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
