import Foundation
import DockerRunnerXPC
import ServiceContracts

/// UI-side client for AgentService XPC (ensure-up, turns, reverse sink).
public final class AgentServiceClient: @unchecked Sendable {
    public static let shared = AgentServiceClient()

    private let serviceName = DerrickServiceID.agent.xpcServiceName
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// True after a successful full ensure-up; cleared when the XPC link dies.
    private var isReady = false
    private let sink = AgentServiceClientSink()

    private init() {}

    /// Install the UI approval handler used when AgentService needs tool confirmation.
    public func setApprovalHandler(
        _ handler: (@Sendable (AgentApprovalRequestDTO) async -> AgentApprovalDecisionDTO)?
    ) {
        sink.setApprovalHandler(handler)
    }

    /// Install the UI network/egress allow handler for AgentService-hosted script runs.
    public func setNetworkAccessHandler(
        _ handler: (@Sendable (AgentNetworkAccessRequestDTO) async -> AgentNetworkAccessDecisionDTO)?
    ) {
        sink.setNetworkAccessHandler(handler)
    }

    /// For chat turns after app bootstrap: reuse the live XPC link; full ensure-up only if down.
    public func ensureReadyForTurn() async throws {
        if hasLiveReadyConnection() { return }
        _ = try await ensureUpAndHealth()
    }

    private nonisolated func hasLiveReadyConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil && isReady
    }

    /// Connect (launch-on-demand), bootstrap DB/logs, return health. Retries a few times.
    /// Use at app startup (and when `ensureReadyForTurn` finds the link dead).
    public func ensureUpAndHealth(retries: Int = 3) async throws -> ServiceHealthReport {
        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            do {
                let proxy = try remoteProxy()
                let boot = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AgentServiceBootstrapResult, Error>) in
                    proxy.bootstrap { data in
                        do {
                            cont.resume(returning: try AgentServiceXPCCodec.decodeBootstrap(data as Data))
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                await MainActor.run {
                    debugLog(
                        "AgentService bootstrap: ok=\(boot.ok) path=\(boot.databasePath ?? "?") msg=\(boot.message)"
                    )
                }
                guard boot.ok else {
                    throw AgentServiceClientError.bootstrapFailed(boot.message)
                }

                let report = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceHealthReport, Error>) in
                    proxy.health { data in
                        do {
                            cont.resume(returning: try AgentServiceXPCCodec.decodeHealth(data as Data))
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                await MainActor.run {
                    debugLog(
                        "AgentService health: status=\(report.status.rawValue) pid=\(report.pid) detail=\(report.detail ?? "")"
                    )
                }
                markReady()
                return report
            } catch {
                lastError = error
                await MainActor.run {
                    debugLog("AgentService ensure-up attempt \(attempt + 1) failed: \(error.localizedDescription)")
                }
                invalidate()
                try? await Task.sleep(nanoseconds: UInt64(100_000_000 * (attempt + 1)))
            }
        }
        throw lastError ?? AgentServiceClientError.unavailable
    }

    private nonisolated func markReady() {
        lock.lock()
        isReady = true
        lock.unlock()
    }

    public func ping(_ text: String) async throws -> String {
        let proxy = try remoteProxy()
        let payload = AgentServiceXPCCodec.encodeString(text) as NSData
        return try await withCheckedThrowingContinuation { cont in
            proxy.ping(payload: payload) { data in
                cont.resume(returning: AgentServiceXPCCodec.decodeString(data as Data))
            }
        }
    }

    /// Streams a turn hosted in AgentService. Yields decoded chunk DTOs until finish.
    public func streamTurn(_ request: AgentTurnRequest) -> AsyncThrowingStream<AgentTurnChunkDTO, Error> {
        AsyncThrowingStream { continuation in
            let turnID = request.turnID
            let finishGate = FinishGate()

            // Preserve approval handler; only bind this turn's chunk/finish stream.
            sink.updateTurnHandlers(
                onChunk: { id, dto in
                    guard id == turnID else { return }
                    continuation.yield(dto)
                },
                onFinish: { id, errorDTO in
                    guard id == turnID else { return }
                    guard finishGate.markFinished() else { return }
                    if let errorDTO {
                        continuation.finish(throwing: AgentServiceClientError.turnFailed(errorDTO.message))
                    } else {
                        continuation.finish()
                    }
                }
            )

            Task {
                do {
                    let proxy = try remoteProxy()
                    let payload = try AgentServiceXPCCodec.encodeTurnRequest(request) as NSData
                    let accepted = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AgentTurnAccepted, Error>) in
                        proxy.startTurn(requestJSON: payload) { data in
                            do {
                                cont.resume(returning: try AgentServiceXPCCodec.decodeTurnAccepted(data as Data))
                            } catch {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                    guard accepted.ok else {
                        guard finishGate.markFinished() else { return }
                        continuation.finish(throwing: AgentServiceClientError.turnFailed(accepted.message))
                        return
                    }
                    await MainActor.run {
                        debugLog("AgentService turn accepted id=\(accepted.turnID) session=\(accepted.sessionID)")
                    }
                } catch {
                    guard finishGate.markFinished() else { return }
                    continuation.finish(throwing: error)
                }
            }

            // Only cancel in-flight work on client cancel — not after a normal finish.
            continuation.onTermination = { @Sendable [weak self] terminal in
                if case .cancelled = terminal {
                    Task {
                        try? await self?.cancelTurn(turnID: turnID)
                    }
                }
            }
        }
    }

    public func cancelTurn(turnID: String) async throws {
        let proxy = try remoteProxy()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.cancelTurn(turnID: turnID) { _ in
                cont.resume()
            }
        }
    }

    /// Deliver MCPService peer listener endpoint into AgentService (pure XPC handoff).
    public func setMCPServicePeerEndpoint(_ endpoint: NSXPCListenerEndpoint) async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.setMCPServicePeerEndpoint(endpoint) { data in
                let text = AgentServiceXPCCodec.decodeString(data as Data)
                if text == "ok" {
                    cont.resume()
                } else {
                    let detail = text.hasPrefix("error:") ? String(text.dropFirst(6)) : text
                    cont.resume(
                        throwing: AgentServiceClientError.turnFailed(
                            detail.isEmpty ? "MCP peer mesh verification failed" : detail
                        )
                    )
                }
            }
        }
        await MainActor.run {
            debugLog("AgentService MCPService peer endpoint handoff ok")
        }
    }

    private func remoteProxy() throws -> AgentServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(serviceName: serviceName)
            let remote = NSXPCInterface(with: AgentServiceXPC.self)
            // Allow NSXPCListenerEndpoint argument on setMCPServicePeerEndpoint:
            remote.setClasses(
                NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>,
                for: #selector(AgentServiceXPC.setMCPServicePeerEndpoint(_:withReply:)),
                argumentIndex: 0,
                ofReply: false
            )
            conn.remoteObjectInterface = remote
            conn.exportedInterface = NSXPCInterface(with: AgentServiceClientSinkXPC.self)
            conn.exportedObject = sink
            do {
                try XPCPeerAuthentication.apply(
                    requirement: XPCPeerAuthentication.requirementString(
                        allowedPeerIdentifiers: [DerrickServiceID.agent.rawValue]
                    ),
                    to: conn
                )
            } catch {
                // Ad-hoc debug builds may still connect.
            }
            conn.interruptionHandler = { [weak self] in
                self?.invalidate()
            }
            conn.invalidationHandler = { [weak self] in
                self?.invalidate()
            }
            conn.resume()
            connection = conn
            Task { @MainActor in
                debugLog("AgentService NSXPCConnection resumed for \(self.serviceName)")
            }
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in
                debugLog("AgentService proxy error: \(error.localizedDescription)")
            }
        }) as? AgentServiceXPC else {
            throw AgentServiceClientError.unavailable
        }
        return proxy
    }

    private nonisolated func invalidate() {
        lock.lock()
        let conn = connection
        connection = nil
        isReady = false
        lock.unlock()
        // Invalidate outside the lock to avoid re-entrancy with invalidationHandler.
        conn?.invalidate()
    }
}

/// One-shot gate so stream finish is only applied once.
private final class FinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    /// Returns true the first time; false if already finished.
    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

public enum AgentServiceClientError: Error, LocalizedError {
    case unavailable
    case bootstrapFailed(String)
    case turnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "AgentService is unavailable. Check service_logs and that AgentService.xpc is embedded."
        case .bootstrapFailed(let message):
            return "AgentService bootstrap failed: \(message)"
        case .turnFailed(let message):
            return "AgentService turn failed: \(message)"
        }
    }
}
