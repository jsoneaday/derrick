import Foundation
import Structure

/// UI / Agent → daemon workflow runtime (XPC from app; in-process when derrickd installs bridges).
public final class WorkflowRuntimeClient: @unchecked Sendable {
    public static let shared = WorkflowRuntimeClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private init() {}

    public func startWorkflow(_ request: WorkflowStartRequest) async throws -> WorkflowHandleDTO {
        if DerrickProcessRole.isDaemon, let start = InProcessServiceBridges.workflowStart {
            return try await start(request)
        }
        let proxy = try remoteProxy()
        let payload = try WorkflowRuntimeXPCCodec.encodeStart(request) as NSData
        return try await withCheckedThrowingContinuation { cont in
            proxy.startWorkflow(requestJSON: payload) { data in
                do {
                    guard !data.isEmpty else {
                        throw WorkflowRuntimeClientError.decodeFailed
                    }
                    cont.resume(returning: try WorkflowRuntimeXPCCodec.decodeHandle(data as Data))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func pollWorkflowUpdate(_ request: WorkflowPollRequest) async throws -> WorkflowPollResultDTO {
        if DerrickProcessRole.isDaemon, let poll = InProcessServiceBridges.workflowPoll {
            return try await poll(request)
        }
        let proxy = try remoteProxy()
        let payload = try WorkflowRuntimeXPCCodec.encodePollRequest(request) as NSData
        return try await withCheckedThrowingContinuation { cont in
            proxy.pollWorkflowUpdate(requestJSON: payload) { data in
                do {
                    guard !data.isEmpty else {
                        throw WorkflowRuntimeClientError.decodeFailed
                    }
                    cont.resume(returning: try WorkflowRuntimeXPCCodec.decodePollResult(data as Data))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func cancelWorkflow(_ request: WorkflowCancelRequest) async throws -> ServiceAckDTO {
        if DerrickProcessRole.isDaemon, let cancel = InProcessServiceBridges.workflowCancel {
            return try await cancel(request)
        }
        let proxy = try remoteProxy()
        let payload = try WorkflowRuntimeXPCCodec.encodeCancel(request) as NSData
        return try await withCheckedThrowingContinuation { cont in
            proxy.cancelWorkflow(requestJSON: payload) { data in
                do {
                    guard !data.isEmpty else {
                        throw WorkflowRuntimeClientError.decodeFailed
                    }
                    cont.resume(returning: try DerrickDaemonXPCCodec.decodeAck(data as Data))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func remoteProxy() throws -> DerrickDaemonServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: DerrickServiceID.daemon.machServiceName)
            let remote = NSXPCInterface(with: DerrickDaemonServiceXPC.self)
            conn.remoteObjectInterface = remote
            conn.resume()
            connection = conn
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.invalidate()
        }) as? DerrickDaemonServiceXPC else {
            throw WorkflowRuntimeClientError.unavailable
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
