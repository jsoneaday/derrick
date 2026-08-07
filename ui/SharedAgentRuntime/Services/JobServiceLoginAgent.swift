import Foundation
import ServiceManagement

/// Registers the keep-alive that holds JobService up for the user session.
///
/// Strategy (reliable for Xcode/dev + production):
/// 1. Best-effort `SMAppService` registration (Login Items / BTM).
/// 2. **Always** run `JobKeepAlive --install-launchd` (non-sandboxed helper writes
///    `~/Library/LaunchAgents` + `launchctl bootstrap`). This is what actually keeps
///    the process alive when SM's submitted job is missing or stuck.
public enum JobServiceLoginAgent {
    public static let plistName = "derrick.ui.JobKeepAlive.plist"
    public static let label = "derrick.ui.JobKeepAlive"

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
            case .missingExecutable(let p): return "JobKeepAlive executable missing: \(p)"
            case .registerFailed(let m): return "Failed to register JobKeepAlive: \(m)"
            }
        }
    }

    private static var smAgent: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    public static var smStatusDescription: String {
        describe(smAgent.status)
    }

    public static func preflightPaths() -> (plist: URL, executable: URL) {
        let root = Bundle.main.bundleURL
        let plist = root
            .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)", isDirectory: false)
        let exe = root
            .appendingPathComponent("Contents/MacOS/JobKeepAlive", isDirectory: false)
        return (plist, exe)
    }

    /// Register / refresh keep-alive. Call from the main actor after JobService is healthy.
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

        fputs(
            "[JobKeepAlive] ensureRegistered bundle=\(Bundle.main.bundleURL.path) sm=\(describe(smAgent.status))\n",
            stderr
        )

        var smDetail = "SM skipped"
        var smOK = false
        do {
            if let r = try registerViaSMAppService() {
                smDetail = r.detail
                smOK = r.isRunningOrEnabled || r.statusDescription.contains("requiresApproval")
            }
        } catch {
            smDetail = "SM failed: \(error.localizedDescription)"
            fputs("[JobKeepAlive] \(smDetail)\n", stderr)
        }

        // Reliable path: non-sandboxed helper installs user LaunchAgent + kickstarts.
        var installDetail = "helper install not run"
        do {
            try runHelperInstall(executable: paths.executable)
            installDetail = "helper --install-launchd ok"
        } catch {
            installDetail = "helper install failed: \(error.localizedDescription)"
            fputs("[JobKeepAlive] \(installDetail)\n", stderr)
        }

        let running = isLaunchdJobLoaded()
        // Success if launchd has the job (even when SM-only path looked flaky).
        if running {
            return Result(
                method: smOK ? .both : .userLaunchAgent,
                statusDescription: "launchd loaded",
                isRunningOrEnabled: true,
                detail: "\(smDetail); \(installDetail); launchdLoaded=true"
            )
        }
        if smOK {
            return Result(
                method: .smAppService,
                statusDescription: smStatusDescription,
                isRunningOrEnabled: true,
                detail: "\(smDetail); \(installDetail); launchdLoaded=false (SM only)"
            )
        }
        throw AgentError.registerFailed(
            "Could not load keep-alive in launchd. \(smDetail); \(installDetail)"
        )
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public static func unregister() throws {
        try? smAgent.unregister()
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistName)")
        let uid = getuid()
        _ = try? runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: dest)
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
            // Force clean re-register when BTM is stale (enabled in BTM but no launchd job).
            try? smAgent.unregister()
            do {
                try smAgent.register()
            } catch {
                fputs(
                    "[JobKeepAlive] SM register error: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)\n",
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

    // MARK: - Helper install (out-of-sandbox launchctl)

    private static func runHelperInstall(executable: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--install-launchd"]
        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !errText.isEmpty {
            fputs(errText, stderr)
        }
        if process.terminationStatus != 0 {
            throw AgentError.registerFailed(
                "JobKeepAlive --install-launchd exit \(process.terminationStatus): \(errText)"
            )
        }
    }

    private static func isLaunchdJobLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        let out = Pipe()
        process.standardOutput = out
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
