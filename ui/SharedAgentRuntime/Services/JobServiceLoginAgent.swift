import Foundation
import ServiceManagement
import ServiceContracts

/// Registers the headless Derrick Daemon LoginAgent for the user session.
///
/// Primary path: `SMAppService` (allowed from the sandboxed UI).
/// Secondary path: spawn daemon `--install-launchd` (writes `~/Library/LaunchAgents`).
/// Helper install often fails when the child inherits the UI sandbox — skip it when SM is already enabled.
public enum JobServiceLoginAgent {
    /// Embedded SMAppService plist under `Contents/Library/LaunchAgents/`.
    public static let plistName = "derrick.ui.Daemon.plist"
    /// Pre-rename SM plist; unregister on upgrade so BTM does not keep a stale agent.
    public static let legacyPlistName = "derrick.ui.JobKeepAlive.plist"
    public static let label = DerrickServiceID.daemon.rawValue
    public static let executableName = "JobKeepAlive"
    /// Relative path inside the host app for the LSUIElement daemon bundle.
    public static let embeddedAppRelativePath = "Contents/Library/LoginItems/JobKeepAlive.app"
    public static let embeddedExecutableRelativePath =
        "\(embeddedAppRelativePath)/Contents/MacOS/\(executableName)"

    public enum Method: String, Sendable {
        case smAppService
        case userLaunchAgent
        case both
    }

    public struct Result: Sendable {
        public let method: Method
        public let statusDescription: String
        public let isRunningOrEnabled: Bool
        public let detail: String
    }

    public enum AgentError: Error, LocalizedError {
        case missingPlist(String)
        case missingExecutable(String)
        case registerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingPlist(let p): return "LaunchAgent plist missing in app bundle: \(p)"
            case .missingExecutable(let p): return "Daemon executable missing: \(p)"
            case .registerFailed(let m): return "Failed to register Derrick daemon: \(m)"
            }
        }
    }

    private static var smAgent: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    private static var legacySMAgent: SMAppService {
        SMAppService.agent(plistName: legacyPlistName)
    }

    public static var smStatusDescription: String {
        describe(smAgent.status)
    }

    public static func preflightPaths() -> (plist: URL, executable: URL) {
        let root = Bundle.main.bundleURL
        let plist = root
            .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)", isDirectory: false)
        let exe = root.appendingPathComponent(embeddedExecutableRelativePath, isDirectory: false)
        return (plist, exe)
    }

    /// Register / refresh daemon. Call from the main actor after services are healthy.
    @MainActor
    @discardableResult
    public static func ensureRegistered() throws -> Result {
        let paths = preflightPaths()
        guard FileManager.default.fileExists(atPath: paths.plist.path) else {
            throw AgentError.missingPlist(paths.plist.path)
        }
        guard FileManager.default.isExecutableFile(atPath: paths.executable.path) else {
            throw AgentError.missingExecutable(paths.executable.path)
        }

        // Drop pre-rename SM registration if present (plist renamed JobKeepAlive → Daemon).
        if legacySMAgent.status != .notRegistered, legacySMAgent.status != .notFound {
            try? legacySMAgent.unregister()
            fputs("[derrickd] unregistered legacy SM agent \(legacyPlistName)\n", stderr)
        }

        fputs(
            "[derrickd] ensureRegistered bundle=\(Bundle.main.bundleURL.path) sm=\(describe(smAgent.status))\n",
            stderr
        )

        var smDetail = "SM skipped"
        var smEnabled = false
        var smNeedsApproval = false
        do {
            if let r = try registerViaSMAppService() {
                smDetail = r.detail
                smEnabled = r.isRunningOrEnabled
                smNeedsApproval = r.statusDescription.contains("requiresApproval")
            }
        } catch {
            smDetail = "SM failed: \(error.localizedDescription)"
            fputs("[derrickd] \(smDetail)\n", stderr)
        }

        // User LaunchAgent only when SM is not already owning the agent.
        var installDetail = "helper install skipped (SM enabled)"
        if !smEnabled {
            if isLaunchdJobLoaded() {
                installDetail = "launchd job already loaded"
            } else {
                do {
                    try runHelperInstall(executable: paths.executable)
                    installDetail = isLaunchdJobLoaded()
                        ? "helper --install-launchd ok"
                        : "helper --install-launchd returned but launchd job not visible"
                } catch {
                    installDetail = "helper install unavailable under App Sandbox: \(error.localizedDescription)"
                    fputs("[derrickd] \(installDetail)\n", stderr)
                }
            }
        }

        let loaded = isLaunchdJobLoaded()
        if loaded {
            return Result(
                method: smEnabled ? .both : .userLaunchAgent,
                statusDescription: "launchd loaded",
                isRunningOrEnabled: true,
                detail: "\(smDetail); \(installDetail); label=\(label); mach=\(DerrickServiceID.daemon.machServiceName)"
            )
        }

        if smEnabled {
            return Result(
                method: .smAppService,
                statusDescription: smStatusDescription,
                isRunningOrEnabled: true,
                detail: "\(smDetail); mach=\(DerrickServiceID.daemon.machServiceName) (demand-start via SM)"
            )
        }

        if smNeedsApproval {
            return Result(
                method: .smAppService,
                statusDescription: "requiresApproval",
                isRunningOrEnabled: false,
                detail: "\(smDetail); \(installDetail)"
            )
        }

        throw AgentError.registerFailed(
            "Could not register derrickd. \(smDetail); \(installDetail). If SM is stuck, run: \(paths.executable.path) --install-launchd"
        )
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public static func unregister() throws {
        try? smAgent.unregister()
        try? legacySMAgent.unregister()
        let uid = getuid()
        _ = try? runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        _ = try? runLaunchctl(["bootout", "gui/\(uid)/\(DerrickServiceID.jobKeepAlive.rawValue)"])
        let home: URL = {
            if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser
        }()
        try? FileManager.default.removeItem(
            at: home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        )
        try? FileManager.default.removeItem(
            at: home.appendingPathComponent(
                "Library/LaunchAgents/\(DerrickServiceID.jobKeepAlive.rawValue).plist"
            )
        )
    }

    // MARK: - SMAppService

    @MainActor
    private static func registerViaSMAppService() throws -> Result? {
        let status = smAgent.status
        switch status {
        case .enabled:
            return Result(
                method: .smAppService,
                statusDescription: describe(status),
                isRunningOrEnabled: true,
                detail: "SMAppService enabled"
            )
        case .requiresApproval:
            openLoginItemsSettings()
            return Result(
                method: .smAppService,
                statusDescription: describe(status),
                isRunningOrEnabled: false,
                detail: "Approve in System Settings → Login Items"
            )
        case .notRegistered, .notFound:
            try? smAgent.unregister()
            do {
                try smAgent.register()
            } catch {
                fputs(
                    "[derrickd] SM register error: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)\n",
                    stderr
                )
                return nil
            }
            let after = smAgent.status
            if after == .requiresApproval { openLoginItemsSettings() }
            if after == .enabled || after == .requiresApproval {
                return Result(
                    method: .smAppService,
                    statusDescription: describe(after),
                    isRunningOrEnabled: after == .enabled,
                    detail: after == .enabled
                        ? "SMAppService registered and enabled"
                        : "SMAppService registered; needs Login Items approval"
                )
            }
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - Helper install

    private static func runHelperInstall(executable: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--install-launchd"]
        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        try process.run()
        let deadline = Date().addingTimeInterval(25)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw AgentError.registerFailed("daemon --install-launchd timed out after 25s")
        }
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !errText.isEmpty {
            fputs(errText, stderr)
        }
        if process.terminationStatus != 0 {
            throw AgentError.registerFailed(
                "daemon --install-launchd exit \(process.terminationStatus): \(errText)"
            )
        }
    }

    private static func isLaunchdJobLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}
