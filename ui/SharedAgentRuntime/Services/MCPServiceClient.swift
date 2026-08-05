import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Client for MCPService over XPC.
///
/// System roles:
/// - **UI process**: `serviceName:` launches Application XPC; used for ensure-up + peer endpoint fetch.
/// - **AgentService process**: connects with a peer `NSXPCListenerEndpoint` installed via handoff.
///   Handoff must **verify** Agent→MCP RPCs before UI marks session ready.
public final class MCPServiceClient: @unchecked Sendable {
    public static let shared = MCPServiceClient()

    private let serviceName = DerrickServiceID.mcp.xpcServiceName
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var peerEndpoint: NSXPCListenerEndpoint?
    private let callTimeoutNanoseconds: UInt64 = 15_000_000_000

    private init() {}

    /// Install peer endpoint in AgentService. Does not prove connectivity — use `verifyPeerMesh()`.
    public func installPeerEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        lock.lock()
        peerEndpoint = endpoint
        connection?.invalidate()
        connection = nil
        lock.unlock()
        fputs("[MCPServiceClient] peer endpoint installed\n", stderr)
    }

    /// AgentService: after install, prove searchTools works over the peer link.
    public func verifyPeerMesh() async throws {
        let result = try await searchTools(principal: .system, query: "")
        guard result.ok else {
            throw MCPServiceClientError.meshUnverified(result.message.isEmpty ? "searchTools not ok" : result.message)
        }
        fputs("[MCPServiceClient] peer mesh verified tools=\(result.tools.count)\n", stderr)
    }

    public func ensureUpAndHealth(retries: Int = 3) async throws -> ServiceHealthReport {
        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            do {
                nonisolated(unsafe) let proxy = try remoteProxy()
                let boot: MCPServiceBootstrapResult = try await invoke(timeout: callTimeoutNanoseconds) {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MCPServiceBootstrapResult, Error>) in
                        proxy.bootstrap { data in
                            do {
                                cont.resume(returning: try MCPServiceXPCCodec.decodeBootstrap(data as Data))
                            } catch {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                }
                await MainActor.run {
                    debugLog("MCPService bootstrap: ok=\(boot.ok) path=\(boot.databasePath ?? "?") msg=\(boot.message)")
                }
                guard boot.ok else {
                    throw MCPServiceClientError.bootstrapFailed(boot.message)
                }
                let report: ServiceHealthReport = try await invoke(timeout: callTimeoutNanoseconds) {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceHealthReport, Error>) in
                        proxy.health { data in
                            do {
                                cont.resume(returning: try MCPServiceXPCCodec.decodeHealth(data as Data))
                            } catch {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                }
                await MainActor.run {
                    debugLog(
                        "MCPService health: status=\(report.status.rawValue) pid=\(report.pid) detail=\(report.detail ?? "")"
                    )
                }
                return report
            } catch {
                lastError = error
                await MainActor.run {
                    debugLog("MCPService ensure-up attempt \(attempt + 1) failed: \(error.localizedDescription)")
                }
                invalidate()
                try? await Task.sleep(nanoseconds: UInt64(100_000_000 * (attempt + 1)))
            }
        }
        throw lastError ?? MCPServiceClientError.unavailable
    }

    public func fetchPeerListenerEndpoint() async throws -> NSXPCListenerEndpoint {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let auth = try MCPServiceXPCCodec.encodeSignedPeerHandoffAuth(
            PeerHandoffAuthDTO(kind: .fetchMCPPeer),
            from: .ui,
            to: .mcp
        ) as NSData
        return try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSXPCListenerEndpoint, Error>) in
                proxy.peerListenerEndpoint(authJSON: auth) { endpoint in
                    cont.resume(returning: endpoint)
                }
            }
        }
    }

    /// Deliver DockerRunnerHelper peer endpoint into MCPService (pure XPC handoff + signed auth).
    public func setDockerHelperPeerEndpoint(_ endpoint: NSXPCListenerEndpoint) async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let auth = try MCPServiceXPCCodec.encodeSignedPeerHandoffAuth(
            PeerHandoffAuthDTO(kind: .installDockerHelperPeer),
            from: .ui,
            to: .mcp
        ) as NSData
        try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.setDockerHelperPeerEndpoint(endpoint, authJSON: auth) { data in
                    do {
                        let ack = try MCPServiceXPCCodec.decodeSignedAck(data as Data, expectedTo: .ui)
                        if ack.ok {
                            cont.resume()
                        } else {
                            cont.resume(
                                throwing: MCPServiceClientError.meshUnverified(
                                    ack.message.isEmpty ? "Docker helper peer mesh verification failed" : ack.message
                                )
                            )
                        }
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        await MainActor.run {
            debugLog("MCPService Docker helper peer endpoint handoff ok")
        }
    }

    public func callTool(_ request: MCPToolCallRequest) async throws -> MCPToolCallResultDTO {
        nonisolated(unsafe) let proxy = try remoteProxy()
        // Signed ServiceMessage envelope (HMAC) — Agent → MCP runTool.
        let payload = try MCPServiceXPCCodec.encodeSignedToolCallRequest(request) as NSData
        return try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.callTool(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try MCPServiceXPCCodec.decodeToolCallResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func searchTools(principal: ServicePrincipal, query: String = "") async throws -> MCPToolSearchResultDTO {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let request = MCPToolSearchRequest(principal: principal, query: query)
        let payload = try MCPServiceXPCCodec.encodeSignedToolSearchRequest(request) as NSData
        return try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.searchTools(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try MCPServiceXPCCodec.decodeToolSearchResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func remoteProxy() throws -> MCPServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            connection = try makeConnection()
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("[MCPServiceClient] proxy error: \(error.localizedDescription)\n", stderr)
            self?.invalidate()
        }) as? MCPServiceXPC else {
            throw MCPServiceClientError.unavailable
        }
        return proxy
    }

    private var isHostApp: Bool {
        (Bundle.main.bundleIdentifier ?? "") == DerrickServiceID.ui.rawValue
    }

    private func makeConnection() throws -> NSXPCConnection {
        if isHostApp {
            let conn = NSXPCConnection(serviceName: serviceName)
            // Host→Application XPC: require MCPService identity.
            configure(conn, codeSignPeerAsMCPService: true)
            conn.resume()
            fputs("[MCPServiceClient] host connected serviceName=\(serviceName)\n", stderr)
            return conn
        }

        guard let endpoint = peerEndpoint else {
            throw MCPServiceClientError.peerEndpointMissing
        }
        let conn = NSXPCConnection(listenerEndpoint: endpoint)
        // Anonymous peer listener: do not set client code-sign requirement.
        // Team/identifier checks on anonymous endpoints reject valid sibling links.
        configure(conn, codeSignPeerAsMCPService: false)
        conn.resume()
        fputs("[MCPServiceClient] peer connected via listener endpoint\n", stderr)
        return conn
    }

    private func configure(_ conn: NSXPCConnection, codeSignPeerAsMCPService: Bool) {
        let remote = NSXPCInterface(with: MCPServiceXPC.self)
        // Allow NSXPCListenerEndpoint argument on setDockerHelperPeerEndpoint:
        remote.setClasses(
            NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>,
            for: #selector(MCPServiceXPC.setDockerHelperPeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        conn.remoteObjectInterface = remote
        if codeSignPeerAsMCPService {
            do {
                try XPCPeerAuthentication.apply(
                    requirement: XPCPeerAuthentication.requirementString(
                        allowedPeerIdentifiers: [DerrickServiceID.mcp.rawValue]
                    ),
                    to: conn
                )
            } catch {
                fputs("[MCPServiceClient] code-sign soft-fail: \(error.localizedDescription)\n", stderr)
            }
        }
        conn.interruptionHandler = { [weak self] in self?.invalidate() }
        conn.invalidationHandler = { [weak self] in self?.invalidate() }
    }

    private func invalidate() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }

    private func invoke<T: Sendable>(
        timeout nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw MCPServiceClientError.timeout
            }
            guard let first = try await group.next() else { throw MCPServiceClientError.timeout }
            group.cancelAll()
            return first
        }
    }
}

public enum MCPServiceClientError: Error, LocalizedError {
    case unavailable
    case bootstrapFailed(String)
    case peerEndpointMissing
    case meshUnverified(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "MCPService is unavailable."
        case .bootstrapFailed(let message):
            return "MCPService bootstrap failed: \(message)"
        case .peerEndpointMissing:
            return "MCPService peer endpoint not installed."
        case .meshUnverified(let message):
            return "Agent→MCPService mesh failed verification: \(message)"
        case .timeout:
            return "MCPService XPC call timed out."
        }
    }
}
