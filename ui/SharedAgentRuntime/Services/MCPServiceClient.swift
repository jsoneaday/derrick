import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Client for MCPService XPC (shared tools with principal).
///
/// - **UI** connects with `NSXPCConnection(serviceName:)` (launches the service).
/// - **AgentService** uses a peer `NSXPCListenerEndpoint` handed off over XPC
///   (UI fetches endpoint from MCPService, then `setMCPServicePeerEndpoint` on AgentService).
public final class MCPServiceClient: @unchecked Sendable {
    public static let shared = MCPServiceClient()

    private let serviceName = DerrickServiceID.mcp.xpcServiceName
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// Installed in AgentService process via UI XPC handoff.
    private var peerEndpoint: NSXPCListenerEndpoint?
    private let callTimeoutNanoseconds: UInt64 = 30_000_000_000

    private init() {}

    /// Called in AgentService when UI delivers MCPService's peer listener endpoint.
    public func installPeerEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        lock.lock()
        peerEndpoint = endpoint
        connection?.invalidate()
        connection = nil
        lock.unlock()
        fputs("[MCPServiceClient] peer endpoint installed in-process\n", stderr)
    }

    public func ensureUpAndHealth(retries: Int = 3) async throws -> ServiceHealthReport {
        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            do {
                nonisolated(unsafe) let proxy = try remoteProxy()
                let boot: MCPServiceBootstrapResult = try await withTimeout(callTimeoutNanoseconds) {
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
                let report: ServiceHealthReport = try await withTimeout(callTimeoutNanoseconds) {
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

    /// UI only: fetch peer listener endpoint over Application XPC for handoff to AgentService.
    public func fetchPeerListenerEndpoint() async throws -> NSXPCListenerEndpoint {
        nonisolated(unsafe) let proxy = try remoteProxy()
        return try await withTimeout(callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSXPCListenerEndpoint, Error>) in
                proxy.peerListenerEndpoint { endpoint in
                    cont.resume(returning: endpoint)
                }
            }
        }
    }

    public func callTool(_ request: MCPToolCallRequest) async throws -> MCPToolCallResultDTO {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try MCPServiceXPCCodec.encodeToolCallRequest(request) as NSData
        return try await withTimeout(callTimeoutNanoseconds) {
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
        let payload = try MCPServiceXPCCodec.encodeToolSearchRequest(request) as NSData
        return try await withTimeout(callTimeoutNanoseconds) {
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
        let id = Bundle.main.bundleIdentifier ?? ""
        return id == DerrickServiceID.ui.rawValue
    }

    private func makeConnection() throws -> NSXPCConnection {
        if isHostApp {
            let conn = NSXPCConnection(serviceName: serviceName)
            configure(conn)
            conn.resume()
            fputs("[MCPServiceClient] connected via serviceName=\(serviceName)\n", stderr)
            return conn
        }

        guard let endpoint = peerEndpoint else {
            fputs("[MCPServiceClient] no peer endpoint (UI must hand off via AgentService XPC)\n", stderr)
            throw MCPServiceClientError.peerEndpointMissing
        }
        let conn = NSXPCConnection(listenerEndpoint: endpoint)
        configure(conn)
        conn.resume()
        fputs("[MCPServiceClient] connected via peer endpoint\n", stderr)
        return conn
    }

    private func configure(_ conn: NSXPCConnection) {
        conn.remoteObjectInterface = NSXPCInterface(with: MCPServiceXPC.self)
        do {
            try XPCPeerAuthentication.apply(
                requirement: XPCPeerAuthentication.requirementString(
                    allowedPeerIdentifiers: [DerrickServiceID.mcp.rawValue]
                ),
                to: conn
            )
        } catch {
            fputs("[MCPServiceClient] peer auth soft-fail: \(error.localizedDescription)\n", stderr)
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

    private func withTimeout<T: Sendable>(
        _ nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw MCPServiceClientError.timeout
            }
            guard let first = try await group.next() else {
                throw MCPServiceClientError.timeout
            }
            group.cancelAll()
            return first
        }
    }
}

public enum MCPServiceClientError: Error, LocalizedError {
    case unavailable
    case bootstrapFailed(String)
    case peerEndpointMissing
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "MCPService is unavailable."
        case .bootstrapFailed(let message):
            return "MCPService bootstrap failed: \(message)"
        case .peerEndpointMissing:
            return "MCPService peer endpoint not installed (UI handoff missing)."
        case .timeout:
            return "MCPService XPC call timed out."
        }
    }
}
