import Foundation
import DockerRunnerXPC
import MCPServer

extension NSData: @unchecked @retroactive Sendable {}

/// PythonScriptRunner in MCPService that runs docker **only** via DockerRunnerHelper peer XPC.
/// UI prewarms volumes/image/warm containers; this path only docker-execs into them.
/// Mid-flight egress prompts stay on the UI↔helper serviceName reverse channel.
final class MCPServiceDockerHelperRunner: PythonScriptRunner, @unchecked Sendable {
    static let shared = MCPServiceDockerHelperRunner()

    private let lock = NSLock()
    private var peerEndpoint: NSXPCListenerEndpoint?
    private var connection: NSXPCConnection?
    private let callTimeoutNanoseconds: UInt64 = 120_000_000_000

    private init() {}

    /// Install helper peer endpoint from UI handoff. Invalidates any prior connection.
    func installPeerEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        lock.lock()
        peerEndpoint = endpoint
        connection?.invalidate()
        connection = nil
        lock.unlock()
        fputs("[MCPService] Docker helper peer endpoint installed\n", stderr)
    }

    /// Prove MCP→helper RPCs work (light egress push round-trip).
    func verifyPeerMesh() async throws {
        let data = try JSONEncoder().encode([String]())
        let ok: Bool = try await withProxy { proxy in
            try await withCheckedThrowingContinuation { cont in
                proxy.setEgressAllowedDomainSuffixes(suffixesJSON: data as NSData) { success in
                    cont.resume(returning: success)
                }
            }
        }
        guard ok else {
            throw MCPServiceDockerHelperError.meshUnverified("setEgressAllowedDomainSuffixes returned false")
        }
        fputs("[MCPService] Docker helper peer mesh verified\n", stderr)
    }

    var hasPeerEndpoint: Bool {
        lock.lock()
        defer { lock.unlock() }
        return peerEndpoint != nil
    }

    func run(
        script: String,
        timeoutSeconds: Int,
        allowNetwork: Bool,
        pythonPackages: [String],
        allowDependencyInstall: Bool
    ) async throws -> PythonScriptExecutionResult {
        let totalStarted = Date()
        let ensureStarted = Date()

        // UI prewarms; still ensure warm container is running via helper (start if stopped).
        try await ensureWarmContainerRunning(allowNetwork: allowNetwork)
        let ensureMS = PythonScriptPhaseTiming.elapsedMS(from: ensureStarted)

        let extras = DockerScriptPreparer.extraPackages(from: pythonPackages)
        let executionScript = DockerScriptPreparer.makeExecutionScript(
            script: script,
            installPackages: extras,
            allowDependencyInstall: allowDependencyInstall,
            nonBaselinePackages: extras
        )
        guard let stdinData = executionScript.data(using: .utf8) else {
            throw MCPServiceDockerHelperError.encodeFailed("execution script")
        }

        let dockerArgs = DockerScriptPreparer.dockerExecArguments(allowNetwork: allowNetwork)
        let request = DockerHostLaunch.makeRequest(
            dockerArguments: dockerArgs,
            stdinData: stdinData,
            timeoutSeconds: timeoutSeconds,
            environment: DockerScriptPreparer.processEnvironment()
        )
        let requestData = try JSONEncoder().encode(request)

        let execStarted = Date()
        let responseData: Data = try await withProxy { proxy in
            try await withCheckedThrowingContinuation { cont in
                proxy.runProcess(requestData: requestData as NSData) { reply in
                    cont.resume(returning: reply as Data)
                }
            }
        }
        let response = try JSONDecoder().decode(DockerRunResponse.self, from: responseData)
        let execMS = PythonScriptPhaseTiming.elapsedMS(from: execStarted)

        if let launchError = response.launchError {
            throw NSError(
                domain: "MCPServer",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: launchError]
            )
        }

        let stdoutText = String(decoding: response.stdout, as: UTF8.self)
        let stderrText = String(decoding: response.stderr, as: UTF8.self)
        let totalMS = PythonScriptPhaseTiming.elapsedMS(from: totalStarted)
        let scriptMetrics = PythonScriptPhaseTiming.scriptMetrics(script)

        if let dockerMessage = DockerScriptPreparer.dockerUnavailableMessage(
            stderr: stderrText,
            exitCode: response.exitCode
        ) {
            throw NSError(
                domain: "MCPServer",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: dockerMessage]
            )
        }

        let phaseTiming = PythonScriptPhaseTiming(
            ensureMS: ensureMS,
            execMS: execMS,
            totalMS: totalMS,
            scriptCharCount: scriptMetrics.chars,
            scriptLineCount: scriptMetrics.lines,
            wrapperCharCount: executionScript.utf8.count
        )
        fputs("[MCPService] \(phaseTiming.summaryLine) runner=helper-xpc\n", stderr)

        return PythonScriptExecutionResult.runnerOutcome(
            timedOut: response.timedOut,
            exitCode: response.exitCode,
            stdout: stdoutText,
            stderr: stderrText,
            durationMS: totalMS,
            phaseTiming: phaseTiming
        )
    }

    // MARK: - Warm container (via helper, not local docker CLI)

    private func ensureWarmContainerRunning(allowNetwork: Bool) async throws {
        let name = DockerScriptPreparer.warmContainerName(allowNetwork: allowNetwork)
        let running = try await runDocker(
            DockerScriptPreparer.dockerInspectContainerRunningArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 15
        )
        let isRunning = String(decoding: running.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        if isRunning { return }

        fputs("[MCPService] warm container \(name) not running; starting via helper\n", stderr)
        let start = try await runDocker(
            DockerScriptPreparer.dockerStartArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 30
        )
        if start.exitCode != 0 {
            let stderr = String(decoding: start.stderr, as: UTF8.self)
            throw NSError(
                domain: "MCPServer",
                code: 503,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Warm container \(name) is not running and could not be started. UI prewarm may have failed. \(stderr)"
                ]
            )
        }
    }

    private func runDocker(_ dockerArguments: [String], timeoutSeconds: Int) async throws -> DockerRunResponse {
        let request = DockerHostLaunch.makeRequest(
            dockerArguments: dockerArguments,
            stdinData: Data(),
            timeoutSeconds: timeoutSeconds,
            environment: DockerScriptPreparer.processEnvironment()
        )
        let requestData = try JSONEncoder().encode(request)
        let responseData: Data = try await withProxy { proxy in
            try await withCheckedThrowingContinuation { cont in
                proxy.runProcess(requestData: requestData as NSData) { reply in
                    cont.resume(returning: reply as Data)
                }
            }
        }
        return try JSONDecoder().decode(DockerRunResponse.self, from: responseData)
    }

    // MARK: - Connection

    private func withProxy<T: Sendable>(
        _ body: @escaping @Sendable (any DockerProcessRunnerXPC) async throws -> T
    ) async throws -> T {
        nonisolated(unsafe) let proxy = try remoteProxy()
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body(proxy) }
            group.addTask {
                try await Task.sleep(nanoseconds: self.callTimeoutNanoseconds)
                throw MCPServiceDockerHelperError.timeout
            }
            guard let first = try await group.next() else {
                throw MCPServiceDockerHelperError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    private func remoteProxy() throws -> any DockerProcessRunnerXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            guard let endpoint = peerEndpoint else {
                throw MCPServiceDockerHelperError.peerEndpointMissing
            }
            let conn = NSXPCConnection(listenerEndpoint: endpoint)
            // Anonymous peer: no client code-sign requirement (same as Agent→MCP mesh).
            conn.remoteObjectInterface = NSXPCInterface(with: DockerProcessRunnerXPC.self)
            conn.interruptionHandler = { [weak self] in self?.invalidateConnection() }
            conn.invalidationHandler = { [weak self] in self?.invalidateConnection() }
            conn.resume()
            connection = conn
            fputs("[MCPService] Docker helper peer connected\n", stderr)
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("[MCPService] Docker helper proxy error: \(error.localizedDescription)\n", stderr)
            self?.invalidateConnection()
        }) as? any DockerProcessRunnerXPC else {
            throw MCPServiceDockerHelperError.unavailable
        }
        return proxy
    }

    private func invalidateConnection() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }
}

enum MCPServiceDockerHelperError: Error, LocalizedError {
    case peerEndpointMissing
    case unavailable
    case meshUnverified(String)
    case timeout
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .peerEndpointMissing:
            return "Docker helper peer endpoint not installed (UI handoff required)."
        case .unavailable:
            return "Docker helper XPC proxy unavailable."
        case .meshUnverified(let m):
            return "MCP→Docker helper mesh failed: \(m)"
        case .timeout:
            return "Docker helper XPC call timed out."
        case .encodeFailed(let what):
            return "Failed to encode \(what)."
        }
    }
}
