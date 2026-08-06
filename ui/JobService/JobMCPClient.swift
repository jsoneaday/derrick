import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Minimal MCP callTool client for JobService (signed envelopes).
final class JobMCPClient: @unchecked Sendable {
    static let shared = JobMCPClient()

    private let serviceName = DerrickServiceID.mcp.xpcServiceName
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private init() {}

    func callTool(_ request: MCPToolCallRequest) async throws -> MCPToolCallResultDTO {
        let proxy = try remoteProxy()
        let payload = try MCPServiceXPCCodec.encodeSignedToolCallRequest(
            request,
            from: .job
        ) as NSData
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

    private func remoteProxy() throws -> MCPServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(serviceName: serviceName)
            let remote = NSXPCInterface(with: MCPServiceXPC.self)
            remote.setClasses(
                NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>,
                for: #selector(MCPServiceXPC.setDockerHelperPeerEndpoint(_:authJSON:withReply:)),
                argumentIndex: 0,
                ofReply: false
            )
            conn.remoteObjectInterface = remote
            do {
                try XPCPeerAuthentication.apply(
                    requirement: XPCPeerAuthentication.requirementString(
                        allowedPeerIdentifiers: [DerrickServiceID.mcp.rawValue]
                    ),
                    to: conn
                )
            } catch {
                fputs("[JobMCPClient] code-sign soft-fail: \(error.localizedDescription)\n", stderr)
            }
            conn.interruptionHandler = { [weak self] in self?.invalidate() }
            conn.invalidationHandler = { [weak self] in self?.invalidate() }
            conn.resume()
            connection = conn
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("[JobMCPClient] proxy error: \(error.localizedDescription)\n", stderr)
            self?.invalidate()
        }) as? MCPServiceXPC else {
            throw JobServiceError.stepFailed("MCPService proxy unavailable")
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
