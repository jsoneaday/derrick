import Foundation
import DBRepository
import DockerRunnerXPC
import EgressProxy
import MCPServer
import MCPToolCatalog
import PolicyUserInteraction
import ServiceContracts

extension NSData: @unchecked @retroactive Sendable {}

/// Reverse XPC sink for daemon → embedded DockerRunnerHelper (logs + egress prompts).
private final class MCPDockerHelperLogSink: NSObject, DockerHelperLogSinkXPC, @unchecked Sendable {
    func appendLog(message: String) {
        fputs("[DockerHelper] \(message)\n", stderr)
    }

    func requestEgressHostAccess(host: String, withReply reply: @escaping @Sendable (NSData) -> Void) {
        // Daemon embedded helper serves scheduled jobs. Network approval is banner-based
        // (HITL notifications), never live-chat modals — those belong to the UI helper path.
        Task {
            let decision: EgressHostAccessReply.Decision
            do {
                let repo = try await MCPServiceStore.shared.sharedRepository()
                let policyDecision = await HITLOfflineNetworkService.awaitDecision(
                    host: host,
                    toolName: AllowedMCPTool.scriptExec.rawValue,
                    turnID: "midflight-\(host)",
                    isJobContext: true,
                    repository: repo,
                    timeoutNanoseconds: 300_000_000_000
                )
                switch policyDecision {
                case .approvedPermanently(let actor):
                    let suffix = EgressHostExtractor.permanentSuffix(for: host)
                    try? await repo.saveEgressAllowedDomainSuffix(
                        EgressAllowedDomainSuffix(suffix: suffix, source: actor ?? "midflight-banner", enabled: true)
                    )
                    let rows = (try? await repo.loadEgressAllowedDomainSuffixes(includeDisabled: false)) ?? []
                    await MCPServiceDockerHelperRunner.shared.pushEgressAllowedDomainSuffixes(
                        rows.filter(\.enabled).map(\.suffix)
                    )
                    decision = .always
                case .approved, .approvedOnce:
                    await MCPServiceDockerHelperRunner.shared.grantEgressSessionHosts([host])
                    decision = .once
                case .denied, .dismissed, .timedOut:
                    decision = .deny
                }
            } catch {
                fputs(
                    "[MCPService] mid-flight egress banner failed host=\(host): \(error.localizedDescription)\n",
                    stderr
                )
                decision = .deny
            }
            let data = (try? EgressHostAccessReply(decision: decision).encodeJSON()) ?? Data("{}".utf8)
            reply(data as NSData)
        }
    }
}

/// MCPService access to DockerRunnerHelper peer XPC.
/// Mid-flight egress prompts stay on the UI↔helper serviceName reverse channel.
final class MCPServiceDockerHelperRunner: @unchecked Sendable {
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

    /// Prewarm the shared Swift runtime image.
    func prewarmSwiftRuntime() async throws {
        try await SwiftDockerContainerPool.shared.prewarm(
            image: SwiftScriptPreparer.image,
            executor: makeStdinCLIExecutor()
        )
    }

    var hasPeerEndpoint: Bool {
        lock.lock()
        defer { lock.unlock() }
        return peerEndpoint != nil
    }

    /// Executor that can attach stdin (script writes, invoke JSON).
    func makeStdinCLIExecutor() -> @Sendable ([String], Data, Int) async throws -> DockerCLIResult {
        { arguments, stdin, timeoutSeconds in
            let response = try await self.runDocker(arguments, stdin: stdin, timeoutSeconds: timeoutSeconds)
            if let launchError = response.launchError {
                return DockerCLIResult(
                    exitCode: response.exitCode == 0 ? 1 : response.exitCode,
                    stdout: response.stdout,
                    stderr: Data(launchError.utf8)
                )
            }
            return DockerCLIResult(
                exitCode: response.exitCode,
                stdout: response.stdout,
                stderr: response.stderr
            )
        }
    }

    private func runDocker(_ dockerArguments: [String], timeoutSeconds: Int) async throws -> DockerRunResponse {
        try await runDocker(dockerArguments, stdin: Data(), timeoutSeconds: timeoutSeconds)
    }

    private func runDocker(
        _ dockerArguments: [String],
        stdin: Data,
        timeoutSeconds: Int
    ) async throws -> DockerRunResponse {
        let request = DockerHostLaunch.makeRequest(
            dockerArguments: dockerArguments,
            stdinData: stdin,
            timeoutSeconds: timeoutSeconds,
            environment: DockerHostLaunch.clientProcessEnvironment()
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

    /// XPC `runProcess` with a racing timeout. Do not invalidate the connection unless
    /// the timeout wins — a leaked sleep used to kill the helper mid-review.
    private func invokeHelper(timeoutNanoseconds: UInt64, requestData: NSData) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    let box = OnceResumeBox(cont)
                    do {
                        let proxy = try self.remoteProxy(onError: { error in
                            box.resume(throwing: error)
                        })
                        proxy.runProcess(requestData: requestData) { reply in
                            box.resume(returning: reply as Data)
                        }
                    } catch {
                        box.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
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
                if case MCPServiceDockerHelperError.timeout = error {
                    self.invalidateConnection()
                }
                throw error
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

    /// Session-only host grants (Allow once) for the embedded helper.
    func grantEgressSessionHosts(_ hosts: [String]) async {
        guard !hosts.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        do {
            let ok: Bool = try await withProxy { proxy in
                try await withCheckedThrowingContinuation { cont in
                    proxy.grantEgressSessionHosts(hostsJSON: data as NSData) { success in
                        cont.resume(returning: success)
                    }
                }
            }
            fputs("[MCPService] egress session grant ok=\(ok) hosts=\(hosts.joined(separator: ","))\n", stderr)
        } catch {
            fputs("[MCPService] egress session grant failed: \(error.localizedDescription)\n", stderr)
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
