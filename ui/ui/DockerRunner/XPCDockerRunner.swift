import Foundation
import DockerRunnerXPC
import MCPServer

extension NSData: @unchecked Sendable {}

private final class XPCAppLogSink: NSObject, DockerHelperLogSinkXPCProtocol, @unchecked Sendable {

    func appendLog(message: String) {
        Task { @MainActor in
            debugLog("[XPC helper] \(message)")
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

/// PythonScriptRunner that delegates docker execution to the DockerRunnerHelper XPC service.
/// The XPC service runs outside the app sandbox and has full access to the Docker socket.
public final class XPCDockerRunner: PythonScriptRunner, @unchecked Sendable {
    private static let serviceName = "derrick.ui.DockerRunnerHelper"
    private let connection: NSXPCConnection
    private let appLogSink: XPCAppLogSink

    private final class PrewarmState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func isCompleted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }

        func markCompleted() {
            lock.lock()
            defer { lock.unlock() }
            completed = true
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
        conn.remoteObjectInterface = NSXPCInterface(with: DockerProcessRunnerXPCProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: DockerHelperLogSinkXPCProtocol.self)
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
        conn.resume()
        self.connection = conn
        debugLog("NSXPCConnection resumed for service \(Self.serviceName).")
        debugLog("XPCDockerRunner initialized for service \(Self.serviceName).")

        Task { @MainActor in
            AppBootstrapStatus.shared.update(
                phase: .connectingHelper,
                message: "Connecting to Docker helper…"
            )
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await prewarmEnvironment()
        }
    }

    private func runXPCCommand(arguments: [String], stdinData: Data = Data(), timeoutSeconds: Int) async throws -> DockerRunResponse {
        let request = DockerRunRequest(
            executablePath: "/usr/bin/env",
            arguments: arguments,
            environment: DockerScriptPreparer.processEnvironment(),
            stdinData: stdinData,
            timeoutSeconds: timeoutSeconds
        )
        let requestData = try JSONEncoder().encode(request)
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = self.connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            guard let service = proxy as? any DockerProcessRunnerXPCProtocol else {
                continuation.resume(throwing: NSError(domain: "XPCDockerRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "XPC service proxy unavailable."]))
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

    private func ensureVolume(_ name: String) async throws {
        let inspect = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerVolumeInspectArguments(name),
            timeoutSeconds: 15
        )
        if inspect.exitCode == 0 { return }
        debugLog("Pre-warming: Creating volume '\(name)'...")
        let create = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerVolumeCreateArguments(name),
            timeoutSeconds: 15
        )
        if create.exitCode != 0 {
            let stderr = String(decoding: create.stderr, as: UTF8.self)
            throw NSError(domain: "XPCDockerRunner", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to create volume \(name): \(stderr)"])
        }
    }

    private func ensureBaselineImage() async throws {
        let inspect = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerImageInspectArguments(DockerScriptPreparer.defaultImage),
            timeoutSeconds: 15
        )
        if inspect.exitCode == 0 {
            debugLog("Baseline image present: \(DockerScriptPreparer.defaultImage)")
            return
        }

        let parentInspect = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerImageInspectArguments(DockerScriptPreparer.parentImage),
            timeoutSeconds: 15
        )
        if parentInspect.exitCode != 0 {
            debugLog("Pre-warming: Pulling parent image '\(DockerScriptPreparer.parentImage)'...")
            let pull = try await runXPCCommand(
                arguments: ["docker"] + DockerScriptPreparer.dockerPullArguments(DockerScriptPreparer.parentImage),
                timeoutSeconds: 300
            )
            if pull.exitCode != 0 {
                let stderr = String(decoding: pull.stderr, as: UTF8.self)
                throw NSError(domain: "XPCDockerRunner", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to pull parent image: \(stderr)"])
            }
        }

        debugLog("Pre-warming: Building baseline image '\(DockerScriptPreparer.defaultImage)'...")
        guard let dockerfileData = DockerScriptPreparer.baselineDockerfile.data(using: .utf8) else {
            throw NSError(domain: "XPCDockerRunner", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to encode Dockerfile."])
        }
        let build = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerBuildBaselineArguments(),
            stdinData: dockerfileData,
            timeoutSeconds: 300
        )
        if build.exitCode != 0 {
            let stderr = String(decoding: build.stderr, as: UTF8.self)
            throw NSError(domain: "XPCDockerRunner", code: 13, userInfo: [NSLocalizedDescriptionKey: "Failed to build baseline image: \(stderr)"])
        }
        debugLog("Pre-warming: Baseline image built successfully.")
    }

    private func ensureWarmContainer(allowNetwork: Bool) async throws {
        let name = DockerScriptPreparer.warmContainerName(allowNetwork: allowNetwork)

        let imageInspect = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerInspectContainerImageArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 15
        )
        let pathInspect = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerInspectContainerPathArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 15
        )
        let imageName = String(decoding: imageInspect.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = String(decoding: pathInspect.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let needsRecreate =
            imageInspect.exitCode != 0
            || imageName != DockerScriptPreparer.defaultImage
            || path != DockerScriptPreparer.warmContainerHoldPath(allowNetwork: allowNetwork)

        if needsRecreate {
            debugLog("Pre-warming: Recreating warm container '\(name)' (image=\(imageName), path=\(path))...")
            _ = try await runXPCCommand(
                arguments: ["docker"] + DockerScriptPreparer.dockerRmForceArguments(container: name),
                timeoutSeconds: 15
            )
            let create = try await runXPCCommand(
                arguments: ["docker"] + DockerScriptPreparer.dockerCreateWarmContainerArguments(allowNetwork: allowNetwork),
                timeoutSeconds: 30
            )
            if create.exitCode != 0 {
                let stderr = String(decoding: create.stderr, as: UTF8.self)
                throw NSError(domain: "XPCDockerRunner", code: 14, userInfo: [NSLocalizedDescriptionKey: "Failed to create warm container \(name): \(stderr)"])
            }
        }

        let runningInspect = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerInspectContainerRunningArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 15
        )
        let running = String(decoding: runningInspect.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if running == "true" {
            debugLog("Warm container already running: \(name)")
            return
        }

        debugLog("Pre-warming: Starting warm container '\(name)'...")
        let start = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerStartArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 30
        )
        if start.exitCode != 0 {
            let stderr = String(decoding: start.stderr, as: UTF8.self)
            throw NSError(domain: "XPCDockerRunner", code: 15, userInfo: [NSLocalizedDescriptionKey: "Failed to start warm container \(name): \(stderr)"])
        }

        let verify = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerInspectContainerRunningArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 15
        )
        let ok = String(decoding: verify.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ok != "true" {
            let stderr = String(decoding: start.stderr, as: UTF8.self)
            throw NSError(
                domain: "XPCDockerRunner",
                code: 19,
                userInfo: [NSLocalizedDescriptionKey: "Warm container \(name) is not running after start. \(stderr)"]
            )
        }
        debugLog("Pre-warming: Warm container '\(name)' is running.")
    }

    private func smokeTestBaseline() async throws {
        let smoke = DockerScriptPreparer.makeBaselineSmokeScript()
        guard let stdinData = smoke.data(using: .utf8) else {
            throw NSError(domain: "XPCDockerRunner", code: 16, userInfo: [NSLocalizedDescriptionKey: "Failed to encode baseline smoke script."])
        }
        debugLog("Pre-warming: Smoke-testing baseline packages via docker exec...")
        let response = try await runXPCCommand(
            arguments: ["docker"] + DockerScriptPreparer.dockerExecArguments(allowNetwork: true),
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
            try await ensureWarmContainer(allowNetwork: true)
            try await ensureWarmContainer(allowNetwork: false)

            await reportBootstrap(phase: .verifyingEnvironment, message: "Verifying runtime environment…")
            try await smokeTestBaseline()

            prewarmState.markCompleted()
            debugLog("Docker environment pre-warming completed successfully.")
            await MainActor.run {
                AppBootstrapStatus.shared.markReady()
            }
        } catch {
            let detail = error.localizedDescription
            debugLog("Docker environment pre-warming failed or was skipped: \(detail)")
            let classified = await MainActor.run {
                AppBootstrapStatus.classifyError(error)
            }
            await MainActor.run {
                AppBootstrapStatus.shared.markFailed(
                    title: classified.title,
                    message: classified.message,
                    technicalDetail: detail
                )
            }
        }
    }

    private func reportBootstrap(phase: AppBootstrapStatus.Phase, message: String) async {
        await MainActor.run {
            AppBootstrapStatus.shared.update(phase: phase, message: message)
        }
    }

    /// Cheap Docker CLI probe so we can surface install/daemon issues before volume/image work.
    private func probeDockerAvailable() async throws {
        let version = try await runXPCCommand(
            arguments: ["docker", "version", "--format", "{{.Server.Version}}"],
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

    /// Ensures warm containers exist even if app-start prewarm failed or was still running.
    private func ensureReadyForRun(allowNetwork: Bool) async throws {
        if !prewarmState.isCompleted() {
            try await ensureVolume(DockerScriptPreparer.pipCacheVolume)
            try await ensureVolume(DockerScriptPreparer.packagesVolume)
            try await ensureBaselineImage()
            try await ensureWarmContainer(allowNetwork: true)
            try await ensureWarmContainer(allowNetwork: false)
            prewarmState.markCompleted()
        } else {
            try await ensureWarmContainer(allowNetwork: allowNetwork)
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
        try await ensureReadyForRun(allowNetwork: allowNetwork)
        let ensureMS = PythonScriptPhaseTiming.elapsedMS(from: ensureStarted)
        debugLog("[python_script_exec timing] ensure_ms=\(ensureMS)")

        let extras = DockerScriptPreparer.extraPackages(from: pythonPackages)
        debugLog("Extra (non-baseline) python packages: \(extras.isEmpty ? "(none)" : extras.joined(separator: ", "))")
        debugLog("Request flags: allowNetwork=\(allowNetwork), allowDependencyInstall=\(allowDependencyInstall), timeoutSeconds=\(timeoutSeconds)")
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
        let dockerArgs = DockerScriptPreparer.dockerExecArguments(allowNetwork: allowNetwork)

        guard let stdinData = executionScript.data(using: .utf8) else {
            throw NSError(domain: "XPCDockerRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode execution script."])
        }

        let request = DockerRunRequest(
            executablePath: "/usr/bin/env",
            arguments: ["docker"] + dockerArgs,
            environment: DockerScriptPreparer.processEnvironment(),
            stdinData: stdinData,
            timeoutSeconds: timeoutSeconds
        )
        let requestData = try JSONEncoder().encode(request)
        debugLog("Prepared XPC payload for helper: bytes=\(requestData.count)")

        let execStarted = Date()
        debugLog("Sending request to XPC helper service.")
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = self.connection.remoteObjectProxyWithErrorHandler { error in
                let nsError = error as NSError
                debugLog("XPC proxy error from service \(Self.serviceName): domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription)")
                continuation.resume(throwing: error)
            }
            guard let service = proxy as? any DockerProcessRunnerXPCProtocol else {
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

        debugLog("Received response from XPC helper.")

        let response = try JSONDecoder().decode(DockerRunResponse.self, from: responseData)
        let execMS = PythonScriptPhaseTiming.elapsedMS(from: execStarted)
        debugLog("[python_script_exec timing] exec_ms=\(execMS)")

        await MainActor.run {
            debugLog("--- Helper Logs ---")
            for log in response.logs {
                debugLog(log)
            }
            debugLog("-------------------")
        }

        if let launchError = response.launchError {
            debugLog("Helper returned launch error: \(launchError)")
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
        debugLog("[python_script_exec timing] runner \(phaseTiming.summaryLine)")
        debugLog("XPC run request finished successfully.")

        return PythonScriptExecutionResult(
            status: response.timedOut ? .timeout : (response.exitCode == 0 ? .completed : .failed),
            decision: (response.timedOut || response.exitCode != 0) ? .deny : .allow,
            verifier: "static-check-v1",
            validationFindings: [],
            reviewerAssessment: nil,
            stdout: stdout,
            stderr: stderr,
            exitCode: response.exitCode,
            timedOut: response.timedOut,
            durationMS: totalMS,
            phaseTiming: phaseTiming
        )
    }
}
