import Foundation
import DockerRunnerXPC
import MCPServer
import ServiceContracts

extension NSData: @unchecked @retroactive Sendable {}

/// Reverse XPC sink for daemon → embedded DockerRunnerHelper (logs + headless egress replies).
private final class MCPDockerHelperLogSink: NSObject, DockerHelperLogSinkXPC, @unchecked Sendable {
    func appendLog(message: String) {
        fputs("[DockerHelper] \(message)\n", stderr)
    }

    func requestEgressHostAccess(host: String, withReply reply: @escaping @Sendable (NSData) -> Void) {
        fputs("[MCPService] mid-flight egress denied (headless) host=\(host)\n", stderr)
        let data = (try? EgressHostAccessReply(decision: .deny).encodeJSON()) ?? Data("{}".utf8)
        reply(data as NSData)
    }
}

/// PythonScriptRunner in MCPService that runs docker **only** via DockerRunnerHelper peer XPC.
/// UI prewarms volumes/image/warm containers; this path only docker-execs into them.
/// Mid-flight egress prompts stay on the UI↔helper serviceName reverse channel.
final class MCPServiceDockerHelperRunner: PythonScriptRunner, @unchecked Sendable {
    static let shared = MCPServiceDockerHelperRunner()

    private let lock = NSLock()
    private var peerEndpoint: NSXPCListenerEndpoint?
    private var connection: NSXPCConnection?
    private let logSink = MCPDockerHelperLogSink()
    private let callTimeoutNanoseconds: UInt64 = 120_000_000_000

    private init() {}

    /// Install helper peer endpoint from UI handoff. Invalidates any prior connection.
    /// Ignored in derrickd — the daemon uses its embedded DockerRunnerHelper so jobs survive UI quit.
    func installPeerEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        if DerrickProcessRole.isDaemon {
            fputs("[MCPService] Docker helper peer handoff ignored (daemon uses embedded helper)\n", stderr)
            return
        }
        lock.lock()
        peerEndpoint = endpoint
        connection?.invalidate()
        connection = nil
        lock.unlock()
        fputs("[MCPService] Docker helper peer endpoint installed\n", stderr)
    }

    /// Prove MCP→helper RPCs work without mutating egress allowlist.
    /// Uses `docker version` (same validation path as real runs).
    func verifyPeerMesh() async throws {
        let response = try await runDocker(["version", "--format", "{{.Server.Version}}"], timeoutSeconds: 20)
        if let launchError = response.launchError {
            throw MCPServiceDockerHelperError.meshUnverified(launchError)
        }
        // exit 0 with empty stdout can still mean daemon not ready; non-zero is hard fail.
        if response.exitCode != 0 {
            let stderr = String(decoding: response.stderr, as: UTF8.self)
            throw MCPServiceDockerHelperError.meshUnverified(
                stderr.isEmpty ? "docker version exit=\(response.exitCode)" : stderr
            )
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
        // Bound by caller timeout (+slack), not the 120s withProxy default — failed helper
        // probes must not hang derrickd bootstrap / job ticks.
        let timeoutNs = UInt64(max(1, timeoutSeconds) + 5) * 1_000_000_000
        let responseData: Data = try await invokeHelper(
            timeoutNanoseconds: timeoutNs,
            requestData: requestData as NSData
        )
        return try JSONDecoder().decode(DockerRunResponse.self, from: responseData)
    }

    /// XPC `runProcess` with single-resume + timeout so helper death cannot leak a continuation.
    private func invokeHelper(timeoutNanoseconds: UInt64, requestData: NSData) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let box = OnceResumeBox(cont)
            do {
                let proxy = try self.remoteProxy(onError: { error in
                    box.resume(throwing: error)
                })
                proxy.runProcess(requestData: requestData) { reply in
                    box.resume(returning: reply as Data)
                }
                Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self.invalidateConnection()
                    box.resume(throwing: MCPServiceDockerHelperError.timeout)
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    // MARK: - Connection

    private func withProxy<T: Sendable>(
        _ body: @escaping @Sendable (any DockerProcessRunnerXPC) async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                let proxy = try self.remoteProxy(onError: { _ in })
                return try await body(proxy)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.callTimeoutNanoseconds)
                self.invalidateConnection()
                throw MCPServiceDockerHelperError.timeout
            }
            do {
                guard let first = try await group.next() else {
                    throw MCPServiceDockerHelperError.timeout
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                self.invalidateConnection()
                throw error
            }
        }
    }

    /// Pushes permanent egress suffixes into the embedded helper (daemon headless path).
    func pushEgressAllowedDomainSuffixes(_ suffixes: [String]) async {
        guard let data = try? JSONEncoder().encode(suffixes) else { return }
        do {
            let ok: Bool = try await withProxy { proxy in
                try await withCheckedThrowingContinuation { cont in
                    proxy.setEgressAllowedDomainSuffixes(suffixesJSON: data as NSData) { success in
                        cont.resume(returning: success)
                    }
                }
            }
            fputs("[MCPService] egress allowlist push ok=\(ok) count=\(suffixes.count)\n", stderr)
        } catch {
            fputs("[MCPService] egress allowlist push failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func remoteProxy(
        onError: (@Sendable (Error) -> Void)? = nil
    ) throws -> any DockerProcessRunnerXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            if DerrickProcessRole.isDaemon {
                let conn = NSXPCConnection(serviceName: "derrick.ui.DockerRunnerHelper")
                do {
                    try XPCPeerAuthentication.apply(
                        requirement: XPCPeerAuthentication.requirementString(
                            allowedPeerIdentifiers: [XPCPeerAuthentication.dockerHelperIdentifier]
                        ),
                        to: conn
                    )
                } catch {
                    fputs("[MCPService] Docker helper auth soft-fail: \(error.localizedDescription)\n", stderr)
                }
                configureConnection(conn)
                conn.resume()
                connection = conn
                fputs("[MCPService] Docker helper serviceName connected (daemon)\n", stderr)
            } else if let endpoint = peerEndpoint {
                let conn = NSXPCConnection(listenerEndpoint: endpoint)
                configureConnection(conn)
                conn.resume()
                connection = conn
                fputs("[MCPService] Docker helper peer connected\n", stderr)
            } else {
                throw MCPServiceDockerHelperError.peerEndpointMissing
            }
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("[MCPService] Docker helper proxy error: \(error.localizedDescription)\n", stderr)
            self?.invalidateConnection()
            onError?(error)
        }) as? any DockerProcessRunnerXPC else {
            throw MCPServiceDockerHelperError.unavailable
        }
        return proxy
    }

    private func configureConnection(_ conn: NSXPCConnection) {
        conn.remoteObjectInterface = NSXPCInterface(with: DockerProcessRunnerXPC.self)
        conn.exportedInterface = NSXPCInterface(with: DockerHelperLogSinkXPC.self)
        conn.exportedObject = logSink
        conn.interruptionHandler = { [weak self] in self?.invalidateConnection() }
        conn.invalidationHandler = { [weak self] in self?.invalidateConnection() }
    }

    private func invalidateConnection() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }
}

/// Ensures a checked continuation is resumed at most once (XPC reply vs error vs timeout).
private final class OnceResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
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
