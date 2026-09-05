import Foundation
import ServiceManagement
import Structure

/// Registers the headless Derrick Daemon LoginAgent for the user session.
///
/// Primary path: `SMAppService` (allowed from the sandboxed UI).
/// Fallback: unsandboxed helper `--install-launchd` with a session launchd label.
/// `~/Library/LaunchAgents/derrick.ui.Daemon.plist` is a BTM-disabled legacy agent;
/// bootstrap of that label returns 5 and SM register returns EPERM.
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
        /// SMAppService is waiting on Login Items. macOS does not show an in-app prompt.
        case needsLoginItemsApproval
        case registerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingPlist(let p): return "LaunchAgent plist missing in app bundle: \(p)"
            case .missingExecutable(let p): return "Daemon executable missing: \(p)"
            case .needsLoginItemsApproval:
                return "Derrick daemon registration requires Login Items approval."
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
    public static func ensureRegistered() async throws -> Result {
        let paths = preflightPaths()
        guard FileManager.default.fileExists(atPath: paths.plist.path) else {
            throw AgentError.missingPlist(paths.plist.path)
        }
        guard FileManager.default.isExecutableFile(atPath: paths.executable.path) else {
            throw AgentError.missingExecutable(paths.executable.path)
        }

        // Drop pre-rename SM registration if present (plist renamed JobKeepAlive → Daemon).
        if legacySMAgent.status != .notRegistered, legacySMAgent.status != .notFound {
            try? await legacySMAgent.unregister()
            fputs("[derrickd] unregistered legacy SM agent \(legacyPlistName)\n", stderr)
        }

        let staleProgram = DerrickDaemonHygiene.isRegisteredDaemonProgramStale(
            registeredProgramPath: registeredLaunchAgentProgramPath(),
            expectedExecutablePath: paths.executable.path
        )
        fputs(
            "[derrickd] ensureRegistered bundle=\(Bundle.main.bundleURL.path) sm=\(describe(smAgent.status)) staleProgram=\(staleProgram)\n",
            stderr
        )

        if staleProgram {
            fputs(
                "[derrickd] launchd still points at a previous app bundle — bootout and reinstall\n",
                stderr
            )
            bootoutRegisteredDaemon()
            try? await smAgent.unregister()
        }

        var smDetail = "SM skipped"
        var smEnabled = false
        do {
            if let r = try registerViaSMAppService() {
                smDetail = r.detail
                smEnabled = r.isRunningOrEnabled
            }
        } catch {
            smDetail = "SM failed: \(error.localizedDescription)"
            fputs("[derrickd] \(smDetail)\n", stderr)
        }

        let loaded = isLaunchdJobLoaded()
        if loaded {
            kickstartRegisteredDaemon()
            return Result(
                method: smEnabled ? .both : .userLaunchAgent,
                statusDescription: "launchd loaded",
                isRunningOrEnabled: true,
                detail: "\(smDetail); label=\(loadedLaunchdLabel() ?? label); mach=\(DerrickServiceID.daemon.machServiceName)"
            )
        }

        // SMAppService can report enabled while the session job is not loaded. The
        // unsandboxed helper installs `derrick.ui.Daemon.session` (BTM-safe).
        do {
            try runHelperInstall(executable: paths.executable)
        } catch {
            fputs("[derrickd] helper --install-launchd failed: \(error.localizedDescription)\n", stderr)
            if smEnabled {
                reloadRegisteredDaemon()
            }
            guard isLaunchdJobLoaded() else {
                throw error
            }
        }
        guard isLaunchdJobLoaded() else {
            throw AgentError.registerFailed(
                "Could not register derrickd. \(smDetail); session launchd job not loaded"
            )
        }
        return Result(
            method: smEnabled ? .both : .userLaunchAgent,
            statusDescription: "launchd loaded",
            isRunningOrEnabled: true,
            detail: "\(smDetail); helper --install-launchd ok; label=\(DerrickServiceID.daemonSessionLaunchdLabel); mach=\(DerrickServiceID.daemon.machServiceName)"
        )
    }

    /// Drop both current and pre-rename launchd jobs so a leftover pid cannot keep the Mach name.
    public static func bootoutRegisteredDaemon() {
        let domains = [
            "gui/\(getuid())/\(label)",
            "gui/\(getuid())/\(DerrickServiceID.daemonSessionLaunchdLabel)",
            "gui/\(getuid())/\(DerrickServiceID.jobKeepAlive.rawValue)",
        ]
        for domain in domains {
            let status = runLaunchctlAllowFail(["bootout", domain])
            fputs("[derrickd] bootout status=\(status) domain=\(domain)\n", stderr)
        }
    }

    /// Load the user LaunchAgent if `bootout` left the job missing, then demand-start it.
    /// `kickstart` does nothing unless the job is already loaded.
    public static func reloadRegisteredDaemon() {
        bootstrapUserLaunchAgentIfNeeded(expectedExecutable: preflightPaths().executable)
        kickstartRegisteredDaemon()
    }

    public static func kickstartRegisteredDaemon() {
        if !isLaunchdJobLoaded() {
            bootstrapUserLaunchAgentIfNeeded(expectedExecutable: preflightPaths().executable)
        }
        guard let domain = loadedLaunchdDomain() else {
            fputs("[derrickd] kickstart skipped — launchd job not loaded\n", stderr)
            return
        }
        let status = runLaunchctlAllowFail(["kickstart", "-k", domain])
        if status != 0 {
            fputs("[derrickd] kickstart status=\(status) domain=\(domain)\n", stderr)
        } else {
            fputs("[derrickd] kickstart ok domain=\(domain)\n", stderr)
        }
    }

    private static func bootstrapUserLaunchAgentIfNeeded(expectedExecutable: URL? = nil) {
        if isLaunchdJobLoaded() { return }
        let plist = sessionLaunchAgentPlistURL()
        guard FileManager.default.fileExists(atPath: plist.path) else {
            fputs("[derrickd] bootstrap skipped — missing \(plist.path)\n", stderr)
            return
        }
        if let expected = expectedExecutable,
           DerrickDaemonHygiene.isRegisteredDaemonProgramStale(
            registeredProgramPath: programPath(inLaunchAgentPlist: plist),
            expectedExecutablePath: expected.path
           ) {
            fputs(
                "[derrickd] bootstrap skipped — \(plist.path) still names a previous app bundle\n",
                stderr
            )
            return
        }
        let uid = getuid()
        let status = runLaunchctlAllowFail(["bootstrap", "gui/\(uid)", plist.path])
        fputs("[derrickd] bootstrap status=\(status) plist=\(plist.path)\n", stderr)
    }

    /// Program path launchd will exec, if we can read a plist we own.
    private static func registeredLaunchAgentProgramPath() -> String? {
        if let fromSession = programPath(inLaunchAgentPlist: sessionLaunchAgentPlistURL()) {
            return fromSession
        }
        if let fromLegacy = programPath(inLaunchAgentPlist: userLaunchAgentPlistURL()) {
            return fromLegacy
        }
        return nil
    }

    private static func programPath(inLaunchAgentPlist plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        if let args = obj["ProgramArguments"] as? [String], let first = args.first, !first.isEmpty {
            return first
        }
        if let program = obj["Program"] as? String, !program.isEmpty {
            return program
        }
        return nil
    }

    private static func userLaunchAgentPlistURL() -> URL {
        realUserHomeDirectory()
            .appendingPathComponent("Library/LaunchAgents/\(label).plist", isDirectory: false)
    }

    private static func sessionLaunchAgentPlistURL() -> URL {
        DerrickAppSupport.daemonSessionLaunchAgentPlistURL(homeDirectory: realUserHomeDirectory())
    }

    private static func isLaunchdJobLoaded() -> Bool {
        loadedLaunchdDomain() != nil
    }

    private static func loadedLaunchdLabel() -> String? {
        loadedLaunchdDomain().map { $0.split(separator: "/").last.map(String.init) ?? $0 }
    }

    private static func loadedLaunchdDomain() -> String? {
        let uid = getuid()
        let names = [
            DerrickServiceID.daemonSessionLaunchdLabel,
            label,
            DerrickServiceID.jobKeepAlive.rawValue,
        ]
        for name in names {
            let domain = "gui/\(uid)/\(name)"
            if isLaunchdDomainLoaded(domain) {
                return domain
            }
        }
        return nil
    }

    private static func isLaunchdDomainLoaded(_ domain: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", domain]
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

    private static func realUserHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    @discardableResult
    private static func runLaunchctlAllowFail(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus != 0, !detail.isEmpty {
                fputs(
                    "[derrickd] launchctl \(arguments.joined(separator: " ")) " +
                    "status=\(process.terminationStatus) detail=\(detail)\n",
                    stderr
                )
            }
            return process.terminationStatus
        } catch {
            fputs(
                "[derrickd] launchctl \(arguments.joined(separator: " ")) failed: \(error.localizedDescription)\n",
                stderr
            )
            return -1
        }
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public static func unregister() throws {
        try? smAgent.unregister()
        try? legacySMAgent.unregister()
        let uid = getuid()
        _ = runLaunchctlAllowFail(["bootout", "gui/\(uid)/\(label)"])
        _ = runLaunchctlAllowFail(["bootout", "gui/\(uid)/\(DerrickServiceID.daemonSessionLaunchdLabel)"])
        _ = runLaunchctlAllowFail(["bootout", "gui/\(uid)/\(DerrickServiceID.jobKeepAlive.rawValue)"])
        let home = realUserHomeDirectory()
        try? FileManager.default.removeItem(
            at: home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        )
        try? FileManager.default.removeItem(
            at: DerrickAppSupport.daemonSessionLaunchAgentPlistURL(homeDirectory: home)
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
            // Do not open Settings here. BTM can report approval-needed while the
            // nested helper still starts when the host app opens it.
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

    /// `DaemonLaunchAgentInstaller` can spend ~30s on bootstrap + kickstart.
    static let helperInstallTimeoutSeconds: TimeInterval = 60

    private static func runHelperInstall(executable: URL) throws {
        // Launch JobKeepAlive.app (not the Mach-O directly). A sandboxed UI spawning the
        // bare binary inherits the UI sandbox and cannot write the session LaunchAgent plist.
        let appURL = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw AgentError.missingExecutable(appURL.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-W", "-n", appURL.path, "--args", "--install-launchd"]
        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        try process.run()
        let deadline = Date().addingTimeInterval(helperInstallTimeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw AgentError.registerFailed(
                "daemon --install-launchd timed out after \(Int(helperInstallTimeoutSeconds))s"
            )
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
