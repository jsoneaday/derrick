import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Shared library: connect or launch Derrick XPC services and verify health.
/// Used by UI, JobService, and (later) WebhookService — single place for ensure-up.
public actor ServiceEnsureUp {
    public static let shared = ServiceEnsureUp()

    private let callTimeoutNanoseconds: UInt64 = 15_000_000_000

    public init() {}

    @discardableResult
    public func ensureAgent(retries: Int = 3) async throws -> ServiceHealthReport {
        try await ensureDaemon(retries: retries)
    }

    @discardableResult
    public func ensureMCP(retries: Int = 3) async throws -> ServiceHealthReport {
        try await ensureDaemon(retries: retries)
    }

    @discardableResult
    public func ensureJob(retries: Int = 3) async throws -> ServiceHealthReport {
        try await ensureDaemon(retries: retries)
    }

    /// Headless backend LoginAgent (`derrick.ui.Daemon`). Prefer this over per-XPC ensure-up as migration completes.
    @discardableResult
    public func ensureDaemon(retries: Int = 3) async throws -> ServiceHealthReport {
        if let hook = ServiceEnsureUpHooks.beforeEnsureDaemon {
            await hook()
        }
        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            do {
                return try await connectDaemon()
            } catch {
                lastError = error
                fputs("[ServiceEnsureUp] Daemon attempt \(attempt + 1): \(error.localizedDescription)\n", stderr)
                try? await Task.sleep(nanoseconds: UInt64(100_000_000 * (attempt + 1)))
            }
        }
        throw lastError ?? ServiceEnsureUpError.unavailable("DerrickDaemon")
    }

    // MARK: - Connections

    private func connectAgent() async throws -> ServiceHealthReport {
        let conn = makeConnection(
            serviceName: DerrickServiceID.agent.xpcServiceName,
            peerID: DerrickServiceID.agent.rawValue,
            interface: AgentServiceXPC.self
        )
        defer { conn.invalidate() }
        nonisolated(unsafe) let proxy = try castProxy(conn, as: AgentServiceXPC.self, label: "AgentService")

        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.bootstrap { data in
                    do {
                        let boot = try AgentServiceXPCCodec.decodeBootstrap(data as Data)
                        if boot.ok { cont.resume() }
                        else { cont.resume(throwing: ServiceEnsureUpError.bootstrapFailed("AgentService", boot.message)) }
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        return try await withTimeout {
            try await withCheckedThrowingContinuation { cont in
                proxy.health { data in
                    do {
                        cont.resume(returning: try AgentServiceXPCCodec.decodeHealth(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func connectMCP() async throws -> ServiceHealthReport {
        let conn = makeConnection(
            serviceName: DerrickServiceID.mcp.xpcServiceName,
            peerID: DerrickServiceID.mcp.rawValue,
            interface: MCPServiceXPC.self
        )
        defer { conn.invalidate() }
        nonisolated(unsafe) let proxy = try castProxy(conn, as: MCPServiceXPC.self, label: "MCPService")

        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.bootstrap { data in
                    do {
                        let boot = try MCPServiceXPCCodec.decodeBootstrap(data as Data)
                        if boot.ok { cont.resume() }
                        else { cont.resume(throwing: ServiceEnsureUpError.bootstrapFailed("MCPService", boot.message)) }
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        return try await withTimeout {
            try await withCheckedThrowingContinuation { cont in
                proxy.health { data in
                    do {
                        cont.resume(returning: try MCPServiceXPCCodec.decodeHealth(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func connectDaemon() async throws -> ServiceHealthReport {
        let conn = NSXPCConnection(machServiceName: DerrickServiceID.daemon.machServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: DerrickDaemonXPC.self)
        do {
            try XPCPeerAuthentication.apply(
                requirement: XPCPeerAuthentication.requirementString(
                    allowedPeerIdentifiers: [DerrickServiceID.daemon.rawValue]
                ),
                to: conn
            )
        } catch {
            fputs("[ServiceEnsureUp] code-sign soft-fail Daemon: \(error.localizedDescription)\n", stderr)
        }
        conn.resume()
        defer { conn.invalidate() }
        nonisolated(unsafe) let proxy = try castProxy(conn, as: DerrickDaemonXPC.self, label: "DerrickDaemon")

        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.bootstrap { data in
                    do {
                        let boot = try DerrickDaemonXPCCodec.decodeBootstrap(data as Data)
                        if boot.ok { cont.resume() }
                        else {
                            cont.resume(
                                throwing: ServiceEnsureUpError.bootstrapFailed("DerrickDaemon", boot.message)
                            )
                        }
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        return try await withTimeout {
            try await withCheckedThrowingContinuation { cont in
                proxy.health { data in
                    do {
                        cont.resume(returning: try DerrickDaemonXPCCodec.decodeHealth(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func connectJob() async throws -> ServiceHealthReport {
        let conn = makeConnection(
            serviceName: DerrickServiceID.job.xpcServiceName,
            peerID: DerrickServiceID.job.rawValue,
            interface: JobServiceXPC.self
        )
        defer { conn.invalidate() }
        nonisolated(unsafe) let proxy = try castProxy(conn, as: JobServiceXPC.self, label: "JobService")

        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.bootstrap { data in
                    do {
                        let boot = try JobServiceXPCCodec.decodeBootstrap(data as Data)
                        if boot.ok { cont.resume() }
                        else { cont.resume(throwing: ServiceEnsureUpError.bootstrapFailed("JobService", boot.message)) }
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        return try await withTimeout {
            try await withCheckedThrowingContinuation { cont in
                proxy.health { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeHealth(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func makeConnection(serviceName: String, peerID: String, interface: Protocol) -> NSXPCConnection {
        let conn = NSXPCConnection(serviceName: serviceName)
        conn.remoteObjectInterface = NSXPCInterface(with: interface)
        do {
            try XPCPeerAuthentication.apply(
                requirement: XPCPeerAuthentication.requirementString(allowedPeerIdentifiers: [peerID]),
                to: conn
            )
        } catch {
            fputs("[ServiceEnsureUp] code-sign soft-fail \(serviceName): \(error.localizedDescription)\n", stderr)
        }
        conn.resume()
        return conn
    }

    private func castProxy<T>(_ conn: NSXPCConnection, as: T.Type, label: String) throws -> T {
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            fputs("[ServiceEnsureUp] \(label) proxy error: \(error.localizedDescription)\n", stderr)
        }) as? T else {
            throw ServiceEnsureUpError.proxyUnavailable(label)
        }
        return proxy
    }

    private func withTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: self.callTimeoutNanoseconds)
                throw ServiceEnsureUpError.timeout
            }
            guard let first = try await group.next() else { throw ServiceEnsureUpError.timeout }
            group.cancelAll()
            return first
        }
    }
}

public enum ServiceEnsureUpError: Error, LocalizedError {
    case proxyUnavailable(String)
    case unavailable(String)
    case bootstrapFailed(String, String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .proxyUnavailable(let label):
            return "\(label) XPC proxy unavailable."
        case .unavailable(let label):
            return "\(label) is unavailable."
        case .bootstrapFailed(let label, let message):
            return "\(label) bootstrap failed: \(message)"
        case .timeout:
            return "Service ensure-up timed out."
        }
    }
}
