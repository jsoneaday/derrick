import Foundation
import AppEvents
import DockerRunnerXPC
import MCPServer
import PolicyUserInteraction
import ServiceContracts

extension NSData: @unchecked @retroactive Sendable {}

/// Ensures an XPC reply continuation is resumed at most once (timeout + late reply race).
private final class XPCPeerEndpointReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<NSXPCListenerEndpoint, Error>?

    init(_ cont: CheckedContinuation<NSXPCListenerEndpoint, Error>) {
        self.cont = cont
    }

    func resume(returning value: NSXPCListenerEndpoint) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}

/// Ensures an XPC reply continuation is resumed at most once (timeout + late reply race).
private final class XPCBoolReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?

    init(_ cont: CheckedContinuation<Bool, Never>) {
        self.cont = cont
    }

    func resume(returning value: Bool) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Ensures an XPC reply continuation is resumed at most once (timeout + late reply race).
private final class XPCReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Data, Error>?

    init(_ cont: CheckedContinuation<Data, Error>) {
        self.cont = cont
    }

    func resume(returning value: Data) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}

private final class XPCAppLogSink: NSObject, DockerHelperLogSinkXPC, @unchecked Sendable {

    func appendLog(message: String) {
        Task { @MainActor in
            debugLog("[XPC helper] \(message)")
        }
    }

    /// Mid-flight CONNECT hold: helper is waiting for once/always/deny before opening upstream.
    func requestEgressHostAccess(host: String, withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task { @MainActor in
            debugLog("[XPC helper] Mid-flight egress prompt for host=\(host)")
            let payload = await EgressAllowlistService.shared.handleMidFlightHostAccess(host: host)
            let data: Data
            if let encoded = try? payload.encodeJSON() {
                data = encoded
            } else {
                data = (try? EgressHostAccessReply(decision: .deny).encodeJSON()) ?? Data("{}".utf8)
            }
            reply(data as NSData)
        }
    }
}

public final class XPCDockerRunnerState: @unchecked Sendable {
    public static let shared = XPCDockerRunnerState()
    
    private let lock = NSLock()
    private var _isCreating = false
    
    public var isCreating: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isCreating
        }
        set {
            lock.lock()
            _isCreating = newValue
            lock.unlock()
        }
    }
}

/// UI-process docker path: prewarm + allowlist push + optional script exec via DockerRunnerHelper
/// Application XPC (`serviceName:`). Outside the sandbox; owns the helper reverse log/egress sink.
///
/// MCPService does **not** use this type — it uses `MCPServiceDockerHelperRunner` over the
/// helper peer endpoint handed off by the UI after prewarm.
public final class XPCDockerRunner: PythonScriptRunner, @unchecked Sendable {
    public static let shared = XPCDockerRunner()

    private static let serviceName = "derrick.ui.DockerRunnerHelper"
    /// First-launch baseline build pulls Chromium; keep this above `baselineImageBuildTimeoutSeconds`.
    private static let prewarmWaitCeilingSeconds: UInt64 = 1_200
    private let connection: NSXPCConnection
    private let appLogSink: XPCAppLogSink

    private final class PrewarmState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var failure: Error?
        private var waiters: [CheckedContinuation<Void, Error>] = []

        func isCompleted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed && failure == nil
        }

        func markCompleted() {
            lock.lock()
            completed = true
            failure = nil
            let pending = waiters
            waiters = []
            lock.unlock()
            for waiter in pending {
                waiter.resume()
            }
        }

        func markFailed(_ error: Error) {
            lock.lock()
            completed = true
            failure = error
            let pending = waiters
            waiters = []
            lock.unlock()
            for waiter in pending {
                waiter.resume(throwing: error)
            }
        }

        func wait() async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if completed {
                    let err = failure
                    lock.unlock()
                    if let err {
                        cont.resume(throwing: err)
                    } else {
                        cont.resume()
                    }
                    return
                }
                waiters.append(cont)
                // Lost race: markCompleted drained an empty waiter list just before we appended.
                if completed {
                    let err = failure
                    lock.unlock()
                    if let err {
                        cont.resume(throwing: err)
                    } else {
                        cont.resume()
                    }
                    return
                }
                lock.unlock()
            }
        }

        func failureIfCompleted() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            guard completed else { return nil }
            return failure
        }
    }

    private let prewarmState = PrewarmState()

    public init() {
        let expectedBundlePath = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("DockerRunnerHelper.xpc", isDirectory: true)
            .path
        let embeddedExists = FileManager.default.fileExists(atPath: expectedBundlePath)
        debugLog("Initializing XPC runner for service \(Self.serviceName).")
        debugLog("Expected embedded helper path: \(expectedBundlePath)")
        debugLog("Embedded helper exists: \(embeddedExists)")

        let appLogSink = XPCAppLogSink()
        self.appLogSink = appLogSink

        let conn = NSXPCConnection(serviceName: Self.serviceName)
        conn.remoteObjectInterface = NSXPCInterface(with: DockerProcessRunnerXPC.self)
        conn.exportedInterface = NSXPCInterface(with: DockerHelperLogSinkXPC.self)
        conn.exportedObject = appLogSink
        conn.interruptionHandler = {
            Task { @MainActor in
                debugLog("XPC connection interrupted for service \(Self.serviceName).")
            }
        }
        conn.invalidationHandler = {
            Task { @MainActor in
                debugLog("XPC connection invalidated for service \(Self.serviceName).")
            }
        }

        // Peer must be the embedded helper (same team when Team ID is available).
        let requirement = XPCPeerAuthentication.requirementString(for: .appConnectingToHelper)
        do {
            try XPCPeerAuthentication.apply(requirement: requirement, to: conn)
            debugLog("XPC peer code-signing requirement applied: \(requirement)")
        } catch {
            debugLog("XPC peer code-signing requirement failed: \(error.localizedDescription) requirement=\(requirement)")
            // Still resume: connection will fail closed on use if peer is wrong; log makes mis-signing visible.
        }

        conn.resume()
        self.connection = conn
        debugLog("NSXPCConnection resumed for service \(Self.serviceName).")
        debugLog("XPCDockerRunner initialized for service \(Self.serviceName).")

        Task { @MainActor in
            guard AppBootstrapStatus.shared.isInitializing else { return }
            AppBootstrapStatus.shared.update(
                phase: .connectingHelper,
                message: "Connecting to Docker helper…"
            )
        }
        // Kick prewarm immediately; callers await via `waitUntilPrewarmed()`.
        Task {
            await prewarmEnvironment()
        }
    }

    /// Wait until docker volumes/image/warm containers are ready (or throw if prewarm failed).
    /// Ceiling is long enough for a cold Chromium bake; timeout fails instead of fake-ready.
    public func waitUntilPrewarmed() async throws {
        if prewarmState.isCompleted() { return }
        if let error = prewarmState.failureIfCompleted() {
            throw error
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.prewarmState.wait()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.prewarmWaitCeilingSeconds * 1_000_000_000)
                let message =
                    "Docker environment setup timed out after \(Self.prewarmWaitCeilingSeconds)s while preparing the Python runtime. Keep Docker Desktop running and retry — first install downloads Chromium and can take several minutes."
                debugLog("Docker prewarm wait hit \(Self.prewarmWaitCeilingSeconds)s ceiling — failing wait (not forcing ready).")
                throw NSError(
                    domain: "XPCDockerRunner",
                    code: 504,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    public var isPrewarmCompleted: Bool {
        prewarmState.isCompleted()
    }

    /// Fetch helper anonymous peer endpoint for handoff to MCPService (UI→MCP only).
    public func fetchPeerListenerEndpoint() async throws -> NSXPCListenerEndpoint {
        try await withThrowingTaskGroup(of: NSXPCListenerEndpoint.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSXPCListenerEndpoint, Error>) in
                    let box = XPCPeerEndpointReplyOnce(continuation)
                    let proxy = self.connection.remoteObjectProxyWithErrorHandler { error in
                        box.resume(throwing: error)
                    }
                    guard let service = proxy as? any DockerProcessRunnerXPC else {
                        box.resume(
                            throwing: NSError(
                                domain: "XPCDockerRunner",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "XPC service proxy unavailable."]
                            )
                        )
                        return
                    }
                    service.peerListenerEndpoint { endpoint in
                        box.resume(returning: endpoint)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw NSError(
                    domain: "XPCDockerRunner",
                    code: 504,
                    userInfo: [NSLocalizedDescriptionKey: "Docker helper peer endpoint timed out."]
                )
            }
            defer { group.cancelAll() }
            guard let endpoint = try await group.next() else {
                throw NSError(
                    domain: "XPCDockerRunner",
                    code: 504,
                    userInfo: [NSLocalizedDescriptionKey: "Docker helper peer endpoint timed out."]
                )
            }
            return endpoint
        }
    }

    /// - Parameter dockerArguments: Args after `docker` (not including the docker token).
    private func runXPCCommand(dockerArguments: [String], stdinData: Data = Data(), timeoutSeconds: Int) async throws -> DockerRunResponse {
        let request = DockerHostLaunch.makeRequest(
            dockerArguments: dockerArguments,
            stdinData: stdinData,
            timeoutSeconds: timeoutSeconds,
            environment: DockerScriptPreparer.processEnvironment()
        )
        let requestData = try JSONEncoder().encode(request)
        // Helper enforces timeoutSeconds on the process; also bound the XPC round-trip so a dead
        // helper / lost reply cannot hang bootstrap forever (was stuck on "Verifying runtime…").
        let clientTimeoutNs = UInt64(max(timeoutSeconds + 15, 30)) * 1_000_000_000
        nonisolated(unsafe) let payload = requestData as NSData
        let responseData: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    let box = XPCReplyOnce(continuation)
                    let proxy = self.connection.remoteObjectProxyWithErrorHandler { error in
                        box.resume(throwing: error)
                    }
                    guard let service = proxy as? any DockerProcessRunnerXPC else {
                        box.resume(
                            throwing: NSError(
                                domain: "XPCDockerRunner",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "XPC service proxy unavailable."]
                            )
                        )
                        return
                    }
                    // Do not hop to MainActor — bootstrap may be waiting on MainActor-isolated UI code.
                    service.runProcess(requestData: payload) { replyNSData in
                        box.resume(returning: replyNSData as Data)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: clientTimeoutNs)
                throw NSError(
                    domain: "XPCDockerRunner",
                    code: 504,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Docker helper XPC timed out after \(timeoutSeconds + 15)s (no reply)."
                    ]
                )
            }
            guard let first = try await group.next() else {
                throw NSError(
                    domain: "XPCDockerRunner",
                    code: 504,
                    userInfo: [NSLocalizedDescriptionKey: "Docker helper XPC timed out."]
                )
            }
            group.cancelAll()
            return first
        }
        let response = try JSONDecoder().decode(DockerRunResponse.self, from: responseData)
        if let launchError = response.launchError {
            await Self.publishXPCValidationFailureIfNeeded(launchError)
        }
        return response
    }

    private static func publishXPCValidationFailureIfNeeded(_ launchError: String) async {
        guard launchError.hasPrefix(DockerRunRequestValidationError.launchErrorPrefix) else { return }
        debugLog("[xpc-validation] \(launchError)")
        let event = PolicyUserEventFactory.xpcValidationFailure(message: launchError)
        await AppEventBus.shared.publish(event)
    }

    /// Pushes permanent domain suffixes into the helper egress proxy.
    public func pushEgressAllowedDomainSuffixes(_ suffixes: [String]) async {
        guard let data = try? JSONEncoder().encode(suffixes) else {
            debugLog("Failed to encode egress allowlist for helper.")
            return
        }
        nonisolated(unsafe) let payload = data as NSData
        let ok = await serviceCallWithTimeout(label: "egress allowlist push") { reply in
            let proxy = self.connection.remoteObjectProxyWithErrorHandler { error in
                debugLog("XPC egress allowlist push failed: \(error.localizedDescription)")
                reply(false)
            }
            guard let service = proxy as? any DockerProcessRunnerXPC else {
                reply(false)
                return
            }
            service.setEgressAllowedDomainSuffixes(suffixesJSON: payload) { success in
                reply(success)
            }
        }
        debugLog("Pushed egress allowlist to helper (ok=\(ok), count=\(suffixes.count))")
    }

    /// Session-only host grants (Allow once) for the helper egress proxy.
    public func grantEgressSessionHosts(_ hosts: [String]) async {
        guard !hosts.isEmpty, let data = try? JSONEncoder().encode(hosts) else { return }
        nonisolated(unsafe) let payload = data as NSData
        let ok = await serviceCallWithTimeout(label: "egress session grant") { reply in
            let proxy = self.connection.remoteObjectProxyWithErrorHandler { error in
                debugLog("XPC egress session grant failed: \(error.localizedDescription)")
                reply(false)
            }
            guard let service = proxy as? any DockerProcessRunnerXPC else {
                reply(false)
                return
            }
            service.grantEgressSessionHosts(hostsJSON: payload) { success in
                reply(success)
            }
        }
        debugLog("Pushed egress session hosts to helper (ok=\(ok), hosts=\(hosts.joined(separator: ",")))")
    }

    private func serviceCallWithTimeout(
        label: String,
        timeoutNanoseconds: UInt64 = 15_000_000_000,
        call: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let box = XPCBoolReplyOnce(continuation)
                    call { success in
                        box.resume(returning: success)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                debugLog("XPC \(label) timed out after \(timeoutNanoseconds / 1_000_000_000)s")
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func ensureVolume(_ name: String) async throws {
        let inspect = try await runXPCCommand(
            dockerArguments: DockerScriptPreparer.dockerVolumeInspectArguments(name),
            timeoutSeconds: 15
        )
        if inspect.exitCode == 0 { return }
        debugLog("Pre-warming: Creating volume '\(name)'...")
        let create = try await runXPCCommand(
            dockerArguments: DockerScriptPreparer.dockerVolumeCreateArguments(name),
            timeoutSeconds: 15
        )
        if create.exitCode != 0 {
            let stderr = String(decoding: create.stderr, as: UTF8.self)
            throw NSError(domain: "XPCDockerRunner", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to create volume \(name): \(stderr)"])
        }
    }

    private func ensureBaselineImage() async throws {
        let inspect = try await runXPCCommand(
            dockerArguments: DockerScriptPreparer.dockerImageInspectArguments(DockerScriptPreparer.defaultImage),
            timeoutSeconds: 15
        )
        if inspect.exitCode == 0 {
            debugLog("Baseline image present: \(DockerScriptPreparer.defaultImage)")
            return
        }

        let parentInspect = try await runXPCCommand(
            dockerArguments: DockerScriptPreparer.dockerImageInspectArguments(DockerScriptPreparer.parentImage),
            timeoutSeconds: 15
        )
        if parentInspect.exitCode != 0 {
            await reportBootstrap(
                phase: .preparingImage,
                message: "Downloading base Python image…"
            )
            debugLog("Pre-warming: Pulling parent image '\(DockerScriptPreparer.parentImage)'...")
            let pull = try await runXPCCommand(
                dockerArguments: DockerScriptPreparer.dockerPullArguments(DockerScriptPreparer.parentImage),
                timeoutSeconds: DockerScriptPreparer.parentImagePullTimeoutSeconds
            )
            if pull.exitCode != 0 {
                let stderr = String(decoding: pull.stderr, as: UTF8.self)
                throw NSError(domain: "XPCDockerRunner", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to pull parent image: \(stderr)"])
            }
        }

        await reportBootstrap(
            phase: .preparingImage,
            message: "Building Python runtime (includes Chromium). First install can take several minutes…"
        )
        debugLog("Pre-warming: Building baseline image '\(DockerScriptPreparer.defaultImage)'...")
        guard let dockerfileData = DockerScriptPreparer.baselineDockerfile.data(using: .utf8) else {
            throw NSError(domain: "XPCDockerRunner", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to encode Dockerfile."])
        }

        let heartbeat = Task {
            var elapsedSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                elapsedSeconds += 30
                let minutes = elapsedSeconds / 60
                let seconds = elapsedSeconds % 60
                let elapsedLabel = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
                await self.reportBootstrap(
                    phase: .preparingImage,
                    message: "Still building Python runtime… (\(elapsedLabel) elapsed). Chromium download is large on first install."
                )
            }
        }
        defer { heartbeat.cancel() }

        let build = try await runXPCCommand(
            dockerArguments: DockerScriptPreparer.dockerBuildBaselineArguments(),
            stdinData: dockerfileData,
            timeoutSeconds: DockerScriptPreparer.baselineImageBuildTimeoutSeconds
        )
        if build.exitCode != 0 {
            let stderr = String(decoding: build.stderr, as: UTF8.self)
            throw NSError(domain: "XPCDockerRunner", code: 13, userInfo: [NSLocalizedDescriptionKey: "Failed to build baseline image: \(stderr)"])
        }
        await reportBootstrap(phase: .preparingImage, message: "Python runtime image ready.")
        debugLog("Pre-warming: Baseline image built successfully.")
    }

    private func prewarmNetworkPool() async throws {
        try await DockerNetworkContainerPool.shared.prewarm(executor: makeCLIExecutor())
    }

    private func makeCLIExecutor() -> DockerCLIExecutor {
        { arguments, timeoutSeconds in
            let response = try await self.runXPCCommand(
                dockerArguments: arguments,
                timeoutSeconds: timeoutSeconds
            )
            if let launchError = response.launchError {
                throw NSError(
                    domain: "XPCDockerRunner",
                    code: 503,
                    userInfo: [NSLocalizedDescriptionKey: launchError]
                )
            }
            return DockerCLIResult(
                exitCode: response.exitCode,
                stdout: response.stdout,
                stderr: response.stderr
            )
        }
    }

    private func smokeTestBaseline() async throws {
        let smoke = DockerScriptPreparer.makeBaselineSmokeScript()
        guard let stdinData = smoke.data(using: .utf8) else {
            throw NSError(domain: "XPCDockerRunner", code: 16, userInfo: [NSLocalizedDescriptionKey: "Failed to encode baseline smoke script."])
        }
        debugLog("Pre-warming: Smoke-testing baseline packages via docker exec...")
        let response = try await runXPCCommand(
            dockerArguments: DockerScriptPreparer.dockerExecArguments(allowNetwork: true),
            stdinData: stdinData,
            timeoutSeconds: 60
        )
        let stdout = String(decoding: response.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: response.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            debugLog("[baseline smoke stdout] \(stdout)")
        }
        if !stderr.isEmpty {
            debugLog("[baseline smoke stderr] \(stderr)")
        }
        if let launchError = response.launchError {
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: launchError])
        }
        if response.exitCode != 0 {
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: "Baseline package smoke test failed with exit code \(response.exitCode)."])
        }
        debugLog("Pre-warming: Baseline package smoke test succeeded.")
    }

    private func prewarmEnvironment() async {
        debugLog("Checking if Docker environment needs pre-warming...")
        XPCDockerRunnerState.shared.isCreating = true
        defer { XPCDockerRunnerState.shared.isCreating = false }
        do {
            await reportBootstrap(phase: .checkingDocker, message: "Checking Docker Desktop…")
            try await probeDockerAvailable()

            await reportBootstrap(phase: .preparingVolumes, message: "Preparing Docker volumes…")
            try await ensureVolume(DockerScriptPreparer.pipCacheVolume)
            try await ensureVolume(DockerScriptPreparer.packagesVolume)

            await reportBootstrap(phase: .preparingImage, message: "Preparing Python runtime image…")
            try await ensureBaselineImage()

            await reportBootstrap(phase: .startingContainers, message: "Starting secure runtime containers…")
            try await prewarmNetworkPool()

            debugLog("Pre-warming: Skipping baseline package smoke (containers ready).")
            prewarmState.markCompleted()
            debugLog("Docker environment pre-warming completed successfully.")
            await reportBootstrap(phase: .verifyingEnvironment, message: "Docker runtime ready.")
            // Do not markReady here — UI bootstrap awaits prewarm, then enables prompting.
        } catch {
            let detail = error.localizedDescription
            debugLog("Docker environment pre-warming failed or was skipped: \(detail)")
            prewarmState.markFailed(error)
        }
    }

    private func reportBootstrap(phase: AppBootstrapStatus.Phase, message: String) async {
        await MainActor.run {
            let status = AppBootstrapStatus.shared
            guard status.isInitializing else { return }
            status.update(phase: phase, message: message)
        }
    }

    /// Cheap Docker CLI probe so we can surface install/daemon issues before volume/image work.
    private func probeDockerAvailable() async throws {
        let version = try await runXPCCommand(
            dockerArguments: ["version", "--format", "{{.Server.Version}}"],
            timeoutSeconds: 20
        )
        let stderr = String(decoding: version.stderr, as: UTF8.self)
        if let dockerMessage = DockerScriptPreparer.dockerUnavailableMessage(
            stderr: stderr,
            exitCode: version.exitCode
        ) {
            throw NSError(
                domain: "XPCDockerRunner",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: dockerMessage]
            )
        }
        if version.exitCode != 0 {
            let stdout = String(decoding: version.stdout, as: UTF8.self)
            let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            if let dockerMessage = DockerScriptPreparer.dockerUnavailableMessage(
                stderr: combined,
                exitCode: version.exitCode
            ) {
                throw NSError(
                    domain: "XPCDockerRunner",
                    code: 503,
                    userInfo: [NSLocalizedDescriptionKey: dockerMessage]
                )
            }
            throw NSError(
                domain: "XPCDockerRunner",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: combined.isEmpty
                    ? "Docker is not available (exit \(version.exitCode))."
                    : combined]
            )
        }
        let serverVersion = String(decoding: version.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverVersion.isEmpty {
            debugLog("Docker engine available (server version \(serverVersion)).")
        } else {
            debugLog("Docker engine available.")
        }
    }

    /// Ensures volumes, image, and pool are ready even if app-start prewarm failed or was still running.
    private func ensureReadyForRun() async throws {
        if !prewarmState.isCompleted() {
            try await ensureVolume(DockerScriptPreparer.pipCacheVolume)
            try await ensureVolume(DockerScriptPreparer.packagesVolume)
            try await ensureBaselineImage()
            try await prewarmNetworkPool()
            prewarmState.markCompleted()
        }
    }

    deinit {
        connection.invalidate()
    }

    public func run(
        script: String,
        timeoutSeconds: Int,
        allowNetwork: Bool,
        pythonPackages: [String],
        allowDependencyInstall: Bool
    ) async throws -> PythonScriptExecutionResult {
        let totalStarted = Date()
        if XPCDockerRunnerState.shared.isCreating {
            debugLog("XPC run request received while script environment is being created.")
        } else {
            debugLog("XPC run request started for docker runner helper.")
        }

        let ensureStarted = Date()
        try await ensureReadyForRun()
        let ensureMS = PythonScriptPhaseTiming.elapsedMS(from: ensureStarted)
        debugLog("[TIME_METRIC] python_script_exec ensure_ms=\(ensureMS)")

        let extras = DockerScriptPreparer.extraPackages(from: pythonPackages)
        debugLog("Extra (non-baseline) python packages: \(extras.isEmpty ? "(none)" : extras.joined(separator: ", "))")
        let effectiveTimeout = DockerScriptPreparer.effectiveScriptTimeoutSeconds(requested: timeoutSeconds)
        debugLog("Request flags: allowNetwork=\(allowNetwork), allowDependencyInstall=\(allowDependencyInstall), timeoutSeconds=\(effectiveTimeout)")
        let executionScript = DockerScriptPreparer.makeExecutionScript(
            script: script,
            installPackages: extras,
            allowDependencyInstall: allowDependencyInstall,
            nonBaselinePackages: extras
        )
        let scriptMetrics = PythonScriptPhaseTiming.scriptMetrics(script)
        debugLog(
            "[python_script_exec] wrapper size: chars=\(executionScript.utf8.count) script_chars=\(scriptMetrics.chars) script_lines=\(scriptMetrics.lines)"
        )
        guard let stdinData = executionScript.data(using: .utf8) else {
            throw NSError(domain: "XPCDockerRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode execution script."])
        }

        let execStarted = Date()
        debugLog("Sending request to XPC helper service.")
        let response: DockerRunResponse = try await DockerNetworkContainerPool.shared.withContainer(
            allowNetwork: allowNetwork,
            executor: makeCLIExecutor()
        ) { containerName in
            let request = DockerHostLaunch.makeRequest(
                dockerArguments: DockerScriptPreparer.dockerExecArguments(containerName: containerName),
                stdinData: stdinData,
                timeoutSeconds: effectiveTimeout,
                environment: DockerScriptPreparer.processEnvironment()
            )
            let requestData = try JSONEncoder().encode(request)
            debugLog("Prepared XPC payload for helper: bytes=\(requestData.count)")
            let responseData: Data = try await withCheckedThrowingContinuation { continuation in
                let proxy = self.connection.remoteObjectProxyWithErrorHandler { error in
                    let nsError = error as NSError
                    debugLog("XPC proxy error from service \(Self.serviceName): domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription)")
                    continuation.resume(throwing: error)
                }
                guard let service = proxy as? any DockerProcessRunnerXPC else {
                    let error = NSError(
                        domain: "XPCDockerRunner", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "XPC service proxy unavailable."])
                    continuation.resume(throwing: error)
                    return
                }
                Task { @MainActor in
                    service.runProcess(requestData: requestData as NSData) { replyNSData in
                        continuation.resume(returning: replyNSData as Data)
                    }
                }
            }
            return try JSONDecoder().decode(DockerRunResponse.self, from: responseData)
        }
        debugLog("Received response from XPC helper.")

        let execMS = PythonScriptPhaseTiming.elapsedMS(from: execStarted)
        debugLog("[TIME_METRIC] python_script_exec exec_ms=\(execMS)")

        await MainActor.run {
            debugLog("--- Helper Logs ---")
            for log in response.logs {
                debugLog(log)
            }
            debugLog("-------------------")
        }

        if let launchError = response.launchError {
            debugLog("Helper returned launch error: \(launchError)")
            await Self.publishXPCValidationFailureIfNeeded(launchError)
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: launchError])
        }

        let stdout = String(decoding: response.stdout, as: UTF8.self)
        let stderr = String(decoding: response.stderr, as: UTF8.self)
        let totalMS = PythonScriptPhaseTiming.elapsedMS(from: totalStarted)

        if let dockerMessage = DockerScriptPreparer.dockerUnavailableMessage(stderr: stderr, exitCode: response.exitCode) {
            debugLog("Docker unavailable message detected: \(dockerMessage)")
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: dockerMessage])
        }

        let phaseTiming = PythonScriptPhaseTiming(
            ensureMS: ensureMS,
            execMS: execMS,
            totalMS: totalMS,
            scriptCharCount: scriptMetrics.chars,
            scriptLineCount: scriptMetrics.lines,
            wrapperCharCount: executionScript.utf8.count
        )
        debugLog("\(phaseTiming.summaryLine) runner=xpc")
        debugLog("XPC run request finished successfully.")

        return PythonScriptExecutionResult.runnerOutcome(
            timedOut: response.timedOut,
            exitCode: response.exitCode,
            stdout: stdout,
            stderr: stderr,
            durationMS: totalMS,
            phaseTiming: phaseTiming
        )
    }
}
