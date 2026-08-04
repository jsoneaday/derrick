import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Client for MCPService XPC (shared tools with principal).
public final class MCPServiceClient: @unchecked Sendable {
    public static let shared = MCPServiceClient()

    private let serviceName = DerrickServiceID.mcp.xpcServiceName
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private init() {}

    public func ensureUpAndHealth(retries: Int = 3) async throws -> ServiceHealthReport {
        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            do {
                let proxy = try remoteProxy()
                let boot = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MCPServiceBootstrapResult, Error>) in
                    proxy.bootstrap { data in
                        do {
                            cont.resume(returning: try MCPServiceXPCCodec.decodeBootstrap(data as Data))
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                await MainActor.run {
                    debugLog("MCPService bootstrap: ok=\(boot.ok) path=\(boot.databasePath ?? "?") msg=\(boot.message)")
                }
                guard boot.ok else {
                    throw MCPServiceClientError.bootstrapFailed(boot.message)
                }
                let report = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceHealthReport, Error>) in
                    proxy.health { data in
                        do {
                            cont.resume(returning: try MCPServiceXPCCodec.decodeHealth(data as Data))
                        } catch {
                            cont.resume(throwing: error)
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

    public func callTool(_ request: MCPToolCallRequest) async throws -> MCPToolCallResultDTO {
        let proxy = try remoteProxy()
        let payload = try MCPServiceXPCCodec.encodeToolCallRequest(request) as NSData
        return try await withCheckedThrowingContinuation { cont in
            proxy.callTool(requestJSON: payload) { data in
                do {
                    cont.resume(returning: try MCPServiceXPCCodec.decodeToolCallResult(data as Data))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func searchTools(principal: ServicePrincipal, query: String = "") async throws -> MCPToolSearchResultDTO {
        let proxy = try remoteProxy()
        let request = MCPToolSearchRequest(principal: principal, query: query)
        let payload = try MCPServiceXPCCodec.encodeToolSearchRequest(request) as NSData
        return try await withCheckedThrowingContinuation { cont in
            proxy.searchTools(requestJSON: payload) { data in
                do {
                    cont.resume(returning: try MCPServiceXPCCodec.decodeToolSearchResult(data as Data))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func remoteProxy() throws -> MCPServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(serviceName: serviceName)
            conn.remoteObjectInterface = NSXPCInterface(with: MCPServiceXPC.self)
            do {
                try XPCPeerAuthentication.apply(
                    requirement: XPCPeerAuthentication.requirementString(
                        allowedPeerIdentifiers: [DerrickServiceID.mcp.rawValue]
                    ),
                    to: conn
                )
            } catch {
                // Ad-hoc debug builds may still connect.
            }
            conn.interruptionHandler = { [weak self] in self?.invalidate() }
            conn.invalidationHandler = { [weak self] in self?.invalidate() }
            conn.resume()
            connection = conn
            Task { @MainActor in
                debugLog("MCPService NSXPCConnection resumed for \(self.serviceName)")
            }
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in
                debugLog("MCPService proxy error: \(error.localizedDescription)")
            }
        }) as? MCPServiceXPC else {
            throw MCPServiceClientError.unavailable
        }
        return proxy
    }

    private func invalidate() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }
}

public enum MCPServiceClientError: Error, LocalizedError {
    case unavailable
    case bootstrapFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "MCPService is unavailable. Check that MCPService.xpc is embedded."
        case .bootstrapFailed(let message):
            return "MCPService bootstrap failed: \(message)"
        }
    }
}
