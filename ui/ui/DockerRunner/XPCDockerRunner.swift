import Foundation
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

        Task {
            // Wait 1 second before pre-warming to let the app fully initialize
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await prewarmEnvironment()
        }
    }

    private func runXPCCommand(arguments: [String], timeoutSeconds: Int) async throws -> DockerRunResponse {
        let request = DockerRunRequest(
            executablePath: "/usr/bin/env",
            arguments: arguments,
            environment: DockerScriptPreparer.processEnvironment(),
            stdinData: Data(),
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

    private func prewarmEnvironment() async {
        debugLog("Checking if Docker environment needs pre-warming...")
        do {
            // 1. Check if the image exists
            let inspectImage = try await runXPCCommand(
                arguments: ["docker", "image", "inspect", DockerScriptPreparer.defaultImage],
                timeoutSeconds: 15
            )
            
            // 2. Check if the volume exists
            let inspectVolume = try await runXPCCommand(
                arguments: ["docker", "volume", "inspect", "derrick-pip-cache"],
                timeoutSeconds: 15
            )
            
            let imageExists = (inspectImage.exitCode == 0)
            let volumeExists = (inspectVolume.exitCode == 0)
            
            if imageExists && volumeExists {
                debugLog("Docker environment is already warm (image and volume exist).")
                return
            }
            
            // Set state to creating
            XPCDockerRunnerState.shared.isCreating = true
            debugLog("Docker environment requires pre-warming. imageExists=\(imageExists), volumeExists=\(volumeExists)")
            
            if !volumeExists {
                debugLog("Pre-warming: Creating volume 'derrick-pip-cache'...")
                _ = try await runXPCCommand(
                    arguments: ["docker", "volume", "create", "derrick-pip-cache"],
                    timeoutSeconds: 15
                )
            }
            
            if !imageExists {
                debugLog("Pre-warming: Pulling image '\(DockerScriptPreparer.defaultImage)' in background...")
                _ = try await runXPCCommand(
                    arguments: ["docker", "pull", DockerScriptPreparer.defaultImage],
                    timeoutSeconds: 300 // Pull can take a while, allow up to 5 mins
                )
            }
            
            debugLog("Docker environment pre-warming completed successfully.")
        } catch {
            debugLog("Docker environment pre-warming failed or was skipped: \(error.localizedDescription)")
        }
        
        XPCDockerRunnerState.shared.isCreating = false
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
        let started = Date()
        if XPCDockerRunnerState.shared.isCreating {
            debugLog("XPC run request received while script environment is being created.")
        } else {
            debugLog("XPC run request started for docker runner helper.")
        }

        let allPackages = pythonPackages + Array(DockerScriptPreparer.baselinePackages)
        let normalizedPackages = DockerScriptPreparer.normalizePackages(allPackages)
        let nonBaselinePackages = normalizedPackages.filter { !DockerScriptPreparer.baselinePackages.contains($0) }
        debugLog("Normalized python packages: \(normalizedPackages.joined(separator: ", "))")
        debugLog("Non-baseline python packages: \(nonBaselinePackages.joined(separator: ", "))")
        debugLog("Request flags: allowNetwork=\(allowNetwork), allowDependencyInstall=\(allowDependencyInstall), timeoutSeconds=\(timeoutSeconds)")
        let executionScript = DockerScriptPreparer.makeExecutionScript(
            script: script,
            installPackages: normalizedPackages,
            allowDependencyInstall: allowDependencyInstall,
            nonBaselinePackages: nonBaselinePackages
        )
        let dockerArgs = DockerScriptPreparer.dockerRunArguments(image: DockerScriptPreparer.defaultImage, allowNetwork: allowNetwork)

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
        let elapsed = Int(Date().timeIntervalSince(started) * 1000.0)

        if let dockerMessage = DockerScriptPreparer.dockerUnavailableMessage(stderr: stderr, exitCode: response.exitCode) {
            debugLog("Docker unavailable message detected: \(dockerMessage)")
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: dockerMessage])
        }

        debugLog("XPC run request finished successfully.")

        return PythonScriptExecutionResult(
            status: response.timedOut ? "timeout" : (response.exitCode == 0 ? "completed" : "failed"),
            decision: (response.timedOut || response.exitCode != 0) ? "deny" : "allow",
            verifier: "static-check-v1",
            findings: [],
            stdout: stdout,
            stderr: stderr,
            exitCode: response.exitCode,
            timedOut: response.timedOut,
            durationMS: elapsed
        )
    }
}
