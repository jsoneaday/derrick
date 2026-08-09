import Foundation
import DockerRunnerXPC
import ServiceContracts

/// JobService → MCPService callTool client (signed envelopes).
///
/// Historically used a **peer** endpoint from UI handoff. Inside derrickd, calls MCP in-process.
final class JobMCPClient: @unchecked Sendable {
    static let shared = JobMCPClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var peerEndpoint: NSXPCListenerEndpoint?
    private let callTimeoutNanoseconds: UInt64 = 120_000_000_000

    private init() {}

    var hasPeerEndpoint: Bool {
        if DerrickProcessRole.isDaemon { return true }
        lock.lock()
        defer { lock.unlock() }
        return peerEndpoint != nil
    }

    func installPeerEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        lock.lock()
        peerEndpoint = endpoint
        connection?.invalidate()
        connection = nil
        lock.unlock()
        JobServiceMeshState.shared.markMCPPeerReady()
        fputs("[JobMCPClient] peer endpoint installed\n", stderr)
    }

    func verifyPeerMesh() async throws {
        if DerrickProcessRole.isDaemon {
            _ = try await MCPServiceToolHost.shared.ensureReady()
            fputs("[JobMCPClient] in-process MCP ready (daemon)\n", stderr)
            return
        }
        nonisolated(unsafe) let proxy = try remoteProxy()
        let report: ServiceHealthReport = try await invoke(timeout: 15_000_000_000) {
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
        guard report.status == .ok else {
            throw JobServiceError.stepFailed(report.detail ?? "MCP health not ok")
        }
        fputs("[JobMCPClient] peer mesh verified status=\(report.status.rawValue)\n", stderr)
    }

    func callTool(_ request: MCPToolCallRequest) async throws -> MCPToolCallResultDTO {
        if DerrickProcessRole.isDaemon {
            return try await MCPServiceToolHost.shared.callTool(request: request)
        }
        nonisolated(unsafe) let proxy = try remoteProxy()
        nonisolated(unsafe) let payload = try MCPServiceXPCCodec.encodeSignedToolCallRequest(
            request,
            from: .job
        ) as NSData
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

    private func remoteProxy() throws -> MCPServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            guard let endpoint = peerEndpoint else {
                throw JobServiceError.stepFailed(
                    "MCPService peer endpoint missing (UI must hand off MCP peer to JobService)"
                )
            }
            let conn = NSXPCConnection(listenerEndpoint: endpoint)
            let remote = NSXPCInterface(with: MCPServiceXPC.self)
            remote.setClasses(
                NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>,
                for: #selector(MCPServiceXPC.setDockerHelperPeerEndpoint(_:authJSON:withReply:)),
                argumentIndex: 0,
                ofReply: false
            )
            conn.remoteObjectInterface = remote
            // Anonymous peer: no code-sign requirement (same as Agent→MCP mesh).
            conn.interruptionHandler = { [weak self] in self?.invalidate() }
            conn.invalidationHandler = { [weak self] in self?.invalidate() }
            conn.resume()
            connection = conn
            fputs("[JobMCPClient] peer connected\n", stderr)
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

    private func invoke<T: Sendable>(
        timeout nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw JobServiceError.stepFailed("MCPService XPC call timed out")
            }
            guard let first = try await group.next() else {
                throw JobServiceError.stepFailed("MCPService XPC call timed out")
            }
            group.cancelAll()
            return first
        }
    }
}
