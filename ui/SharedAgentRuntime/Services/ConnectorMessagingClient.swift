import DBRepository
import Foundation
import Structure

/// UI → daemon connector bootstrap/send (short XPC submit/poll; Docker runs in derrickd).
public final class ConnectorMessagingClient: @unchecked Sendable {
    public static let shared = ConnectorMessagingClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let pollIntervalNanoseconds: UInt64 = 300_000_000
    private let operationTimeoutNanoseconds: UInt64 = MCPToolCallTimeouts.pluginInvokeNanoseconds

    private init() {}

    public func bootstrap(pluginID: String) async throws {
        let request = ConnectorOperationRequest(
            operationID: UUID().uuidString,
            pluginID: pluginID,
            kind: .bootstrap
        )
        try await run(request)
    }

    public func send(
        pluginID: String,
        vendorThreadID: String,
        threadID: String,
        text: String
    ) async throws {
        let request = ConnectorOperationRequest(
            operationID: UUID().uuidString,
            pluginID: pluginID,
            kind: .send,
            vendorThreadID: vendorThreadID,
            threadID: threadID,
            text: text
        )
        try await run(request)
    }

    private func run(_ request: ConnectorOperationRequest) async throws {
        await log(
            level: .info,
            code: "submit",
            message: "Connector \(request.kind.rawValue) starting pluginID=\(request.pluginID) operationID=\(request.operationID)",
            request: request
        )
        let ack: ConnectorOperationAckDTO
        do {
            ack = try await submit(request)
        } catch {
            await log(
                level: .error,
                code: "submit_failed",
                message: "Connector \(request.kind.rawValue) submit failed: \(error.localizedDescription)",
                request: request,
                extra: ["error": error.localizedDescription]
            )
            throw error
        }
        guard ack.accepted else {
            await log(
                level: .error,
                code: "not_accepted",
                message: "Connector \(request.kind.rawValue) rejected: \(ack.message)",
                request: request,
                extra: ["ackMessage": ack.message]
            )
            throw ConnectorMessagingClientError.notAccepted(ack.message)
        }
        await log(
            level: .debug,
            code: "accepted",
            message: "Connector \(request.kind.rawValue) accepted operationID=\(request.operationID)",
            request: request
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + operationTimeoutNanoseconds
        var pollCount = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let poll = try await poll(ConnectorOperationPollRequest(operationID: request.operationID))
            pollCount += 1
            switch poll.status {
            case .running:
                if pollCount == 1 || pollCount % 10 == 0 {
                    await log(
                        level: .debug,
                        code: "poll_running",
                        message: "Connector \(request.kind.rawValue) still running poll=\(pollCount) operationID=\(request.operationID)",
                        request: request,
                        extra: ["pollCount": "\(pollCount)"]
                    )
                }
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            case .completed:
                await log(
                    level: .info,
                    code: "completed",
                    message: "Connector \(request.kind.rawValue) completed after \(pollCount) polls operationID=\(request.operationID)",
                    request: request,
                    extra: ["pollCount": "\(pollCount)"]
                )
                return
            case .failed:
                let detail = poll.error ?? "Connector operation failed."
                await log(
                    level: .error,
                    code: "failed",
                    message: "Connector \(request.kind.rawValue) failed: \(detail)",
                    request: request,
                    extra: ["pollCount": "\(pollCount)", "error": detail]
                )
                throw ConnectorMessagingClientError.operationFailed(detail)
            }
        }
        await log(
            level: .error,
            code: "timeout",
            message: "Connector \(request.kind.rawValue) timed out after \(pollCount) polls operationID=\(request.operationID)",
            request: request,
            extra: ["pollCount": "\(pollCount)", "timeoutSeconds": "\(operationTimeoutNanoseconds / 1_000_000_000)"]
        )
        throw ConnectorMessagingClientError.timedOut
    }

    private func submit(_ request: ConnectorOperationRequest) async throws -> ConnectorOperationAckDTO {
        if DerrickProcessRole.isDaemon, let submit = InProcessServiceBridges.connectorSubmit {
            return try await submit(request)
        }
        let proxy = try remoteProxy()
        let payload = try ConnectorMessagingXPCCodec.encodeSubmit(request) as NSData
        return try await withCheckedThrowingContinuation { cont in
            proxy.submitConnectorOperation(requestJSON: payload) { data in
                do {
                    guard !data.isEmpty else {
                        throw ConnectorMessagingClientError.decodeFailed
                    }
                    cont.resume(returning: try ConnectorMessagingXPCCodec.decodeAck(data as Data))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func poll(_ request: ConnectorOperationPollRequest) async throws -> ConnectorOperationPollResult {
        if DerrickProcessRole.isDaemon, let poll = InProcessServiceBridges.connectorPoll {
            return try await poll(request)
        }
        let proxy = try remoteProxy()
        let payload = try ConnectorMessagingXPCCodec.encodePollRequest(request) as NSData
        return try await withCheckedThrowingContinuation { cont in
            proxy.pollConnectorOperation(requestJSON: payload) { data in
                do {
                    guard !data.isEmpty else {
                        throw ConnectorMessagingClientError.decodeFailed
                    }
                    cont.resume(returning: try ConnectorMessagingXPCCodec.decodePollResult(data as Data))
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
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task {
                await ServiceLogRecorder.shared.record(
                    service: "connector",
                    level: .warning,
                    code: "xpc_error",
                    message: "Connector messaging XPC error: \(error.localizedDescription)"
                )
            }
            self?.invalidate()
        }) as? DerrickDaemonServiceXPC else {
            throw ConnectorMessagingClientError.unavailable
        }
        return proxy
    }

    private func invalidate() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }

    private func log(
        level: ServiceLogLevel,
        code: String,
        message: String,
        request: ConnectorOperationRequest,
        extra: [String: String] = [:]
    ) async {
        var payload: [String: String] = [
            "operationID": request.operationID,
            "pluginID": request.pluginID,
            "kind": request.kind.rawValue,
            "process": DerrickProcessRole.isDaemon ? "daemon" : "ui"
        ]
        if let vendorThreadID = request.vendorThreadID {
            payload["vendorThreadID"] = vendorThreadID
        }
        if let threadID = request.threadID {
            payload["threadID"] = threadID
        }
        if let text = request.text {
            payload["textLength"] = "\(text.count)"
            payload["textPreview"] = String(text.prefix(120))
        }
        for (key, value) in extra {
            payload[key] = value
        }
        let detailJSON = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) }
        await ServiceLogRecorder.shared.record(
            service: "connector",
            level: level,
            code: code,
            message: message,
            detailJSON: detailJSON
        )
    }
}
