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
        debugLog("XPC run request started for docker runner helper.")

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
