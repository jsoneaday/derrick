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
    private let turnStreamHub = TurnStreamHub()
    private let callTimeoutNanoseconds: UInt64 = 15_000_000_000

    private init() {
        sink.updateTurnHandlers(
            onChunk: { [turnStreamHub] turnID, dto in
                turnStreamHub.deliverChunk(turnID: turnID, dto: dto)
            },
            onFinish: { [turnStreamHub, sink] turnID, errorDTO in
                sink.endForegroundTurn(turnID)
                turnStreamHub.deliverFinish(turnID: turnID, errorDTO: errorDTO)
            }
        )
    }

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

    public func setPolicyDecisionHandler(
        _ handler: (@Sendable (AgentPolicyDecisionRequestDTO) async -> AgentPolicyDecisionDTO)?
    ) {
        sink.setPolicyDecisionHandler(handler)
    }

    /// Job wakeAgent turns stream here (not the active user `streamTurn`).
    public func setBackgroundTurnHandlers(
        onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)?,
        onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)?
    ) {
        sink.setBackgroundTurnHandlers(onChunk: onChunk, onFinish: onFinish)
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

    /// Drop a dead Mach connection so the next ensure-up opens a new one (e.g. after daemon eviction).
    public func dropConnectionForReconnect() {
        invalidate()
    }

    /// Connect (launch-on-demand), bootstrap DB/logs, return health. Retries a few times.
    /// Use at app startup (and when `ensureReadyForTurn` finds the link dead).
    public func ensureUpAndHealth(retries: Int = 3) async throws -> ServiceHealthReport {
        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            do {
                nonisolated(unsafe) let proxy = try remoteProxy()
                let boot: DerrickDaemonBootstrapResult = try await invoke(timeout: callTimeoutNanoseconds) {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DerrickDaemonBootstrapResult, Error>) in
                        proxy.bootstrap { data in
                            do {
                                cont.resume(returning: try DerrickDaemonXPCCodec.decodeBootstrap(data as Data))
                            } catch {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                }
                await MainActor.run {
                    debugLog(
                        "Daemon/Agent bootstrap: ok=\(boot.ok) path=\(boot.databasePath ?? "?") modules=\(boot.modules) msg=\(boot.message)"
                    )
                }
                guard boot.ok else {
                    throw AgentServiceClientError.bootstrapFailed(boot.message)
                }

                let report: ServiceHealthReport = try await invoke(timeout: callTimeoutNanoseconds) {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceHealthReport, Error>) in
                        proxy.health { data in
                            do {
                                cont.resume(returning: try AgentServiceXPCCodec.decodeHealth(data as Data))
                            } catch {
                                cont.resume(throwing: error)
                            }
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
            let finishGate = turnStreamHub.register(turnID: turnID, continuation: continuation)
            sink.beginForegroundTurn(turnID)

            continuation.onTermination = { @Sendable [weak self, weak sink] terminal in
                if case .cancelled = terminal {
                    sink?.endForegroundTurn(turnID)
                    self?.turnStreamHub.remove(turnID: turnID)
                    Task {
                        try? await self?.cancelTurn(turnID: turnID)
                    }
                }
            }

            Task {
                do {
                    let proxy = try self.remoteProxy()
                    let payload = try AgentServiceXPCCodec.encodeSignedTurnRequest(request) as NSData
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
                        sink.endForegroundTurn(turnID)
                        turnStreamHub.deliverFinish(
                            turnID: turnID,
                            errorDTO: AgentTurnErrorDTO(turnID: turnID, message: accepted.message, code: "rejected")
                        )
                        return
                    }
                    await MainActor.run {
                        debugLog("AgentService turn accepted id=\(accepted.turnID) session=\(accepted.sessionID)")
                    }
                } catch {
                    sink.endForegroundTurn(turnID)
                    guard finishGate.markFinished() else { return }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Fetch AgentService anonymous peer endpoint (for JobService handoff).
    public func fetchPeerListenerEndpoint() async throws -> NSXPCListenerEndpoint {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let auth = try AgentServiceXPCCodec.encodeSignedPeerHandoffAuth(
            PeerHandoffAuthDTO(kind: .fetchAgentPeer),
            from: .ui,
            to: .agent
        ) as NSData
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSXPCListenerEndpoint, Error>) in
            proxy.peerListenerEndpoint(authJSON: auth) { endpoint in
                cont.resume(returning: endpoint)
            }
        }
    }

    /// Deliver DockerRunnerHelper peer endpoint into daemon MCP (best-effort; daemon uses embedded helper when UI is quit).
    public func setDockerHelperPeerEndpoint(_ endpoint: NSXPCListenerEndpoint) async throws {
        guard let daemonProxy = try remoteProxy() as? DerrickDaemonServiceXPC else {
            throw AgentServiceClientError.unavailable
        }
        nonisolated(unsafe) let proxy = daemonProxy
        let auth = try MCPServiceXPCCodec.encodeSignedPeerHandoffAuth(
            PeerHandoffAuthDTO(kind: .installDockerHelperPeer),
            from: .ui,
            to: .mcp
        ) as NSData
        try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.setDockerHelperPeerEndpoint(endpoint, authJSON: auth) { data in
                    do {
                        let ack = try Self.decodeDockerHelperHandoffAck(data as Data)
                        if ack.ok {
                            cont.resume()
                        } else {
                            cont.resume(
                                throwing: AgentServiceClientError.turnFailed(
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
            debugLog("Daemon MCP Docker helper peer endpoint handoff ok")
        }
    }

    private static func decodeDockerHelperHandoffAck(_ data: Data) throws -> ServiceAckDTO {
        if data.isEmpty {
            throw AgentServiceClientError.turnFailed("empty docker helper handoff reply")
        }
        if let signed = try? MCPServiceXPCCodec.decodeSignedAck(data, expectedTo: .ui) {
            return signed
        }
        return try DerrickDaemonXPCCodec.decodeAck(data)
    }

    public func cancelTurn(turnID: String) async throws {
        let proxy = try remoteProxy()
        let payload = try AgentServiceXPCCodec.encodeSignedCancelTurn(turnID: turnID) as NSData
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.cancelTurn(requestJSON: payload) { data in
                do {
                    let ack = try AgentServiceXPCCodec.decodeSignedAck(data as Data, expectedTo: .ui)
                    if ack.ok {
                        cont.resume()
                    } else {
                        cont.resume(throwing: AgentServiceClientError.turnFailed(ack.message))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Deliver MCPService peer listener endpoint into AgentService (pure XPC handoff + signed auth).
    public func setMCPServicePeerEndpoint(_ endpoint: NSXPCListenerEndpoint) async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let auth = try AgentServiceXPCCodec.encodeSignedPeerHandoffAuth(
            PeerHandoffAuthDTO(kind: .installMCPPeer),
            from: .ui,
            to: .agent
        ) as NSData
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.setMCPServicePeerEndpoint(endpoint, authJSON: auth) { data in
                do {
                    let ack = try AgentServiceXPCCodec.decodeSignedAck(data as Data, expectedTo: .ui)
                    if ack.ok {
                        cont.resume()
                    } else {
                        cont.resume(
                            throwing: AgentServiceClientError.turnFailed(
                                ack.message.isEmpty ? "MCP peer mesh verification failed" : ack.message
                            )
                        )
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        await MainActor.run {
            debugLog("AgentService MCPService peer endpoint handoff ok")
        }
    }

    /// Deliver JobService peer listener endpoint into AgentService (pure XPC handoff + signed auth).
    public func setJobServicePeerEndpoint(_ endpoint: NSXPCListenerEndpoint) async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let auth = try AgentServiceXPCCodec.encodeSignedPeerHandoffAuth(
            PeerHandoffAuthDTO(kind: .installJobPeer),
            from: .ui,
            to: .agent
        ) as NSData
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.setJobServicePeerEndpoint(endpoint, authJSON: auth) { data in
                do {
                    let ack = try AgentServiceXPCCodec.decodeSignedAck(data as Data, expectedTo: .ui)
                    if ack.ok {
                        cont.resume()
                    } else {
                        cont.resume(
                            throwing: AgentServiceClientError.turnFailed(
                                ack.message.isEmpty ? "Job peer mesh verification failed" : ack.message
                            )
                        )
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        await MainActor.run {
            debugLog("AgentService JobService peer endpoint handoff ok")
        }
    }

    public func listEgressBlacklist() async throws -> [EgressBlacklistEntryDTO] {
        try await ensureReadyForTurn()
        nonisolated(unsafe) let proxy = try remoteProxy()
        return try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[EgressBlacklistEntryDTO], Error>) in
                proxy.listEgressBlacklist { data in
                    do {
                        cont.resume(returning: try DerrickDaemonXPCCodec.decodeBlacklistList(data as Data).entries)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func addEgressBlacklist(pattern: String) async throws {
        try await ensureReadyForTurn()
        let payload = try DerrickDaemonXPCCodec.encodeBlacklistAddRequest(
            EgressBlacklistAddRequest(pattern: pattern)
        )
        nonisolated(unsafe) let proxy = try remoteProxy()
        nonisolated(unsafe) let nsPayload = payload as NSData
        let ack: ServiceAckDTO = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceAckDTO, Error>) in
                proxy.addEgressBlacklist(requestJSON: nsPayload) { data in
                    do {
                        cont.resume(returning: try DerrickDaemonXPCCodec.decodeAck(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard ack.ok else {
            throw AgentServiceClientError.rejected(ack.message)
        }
    }

    public func removeEgressBlacklist(id: String) async throws {
        try await ensureReadyForTurn()
        let payload = try DerrickDaemonXPCCodec.encodeBlacklistRemoveRequest(
            EgressBlacklistRemoveRequest(id: id)
        )
        nonisolated(unsafe) let proxy = try remoteProxy()
        nonisolated(unsafe) let nsPayload = payload as NSData
        let ack: ServiceAckDTO = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceAckDTO, Error>) in
                proxy.removeEgressBlacklist(requestJSON: nsPayload) { data in
                    do {
                        cont.resume(returning: try DerrickDaemonXPCCodec.decodeAck(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard ack.ok else {
            throw AgentServiceClientError.rejected(ack.message)
        }
    }

    private func remoteProxy() throws -> DerrickDaemonServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: DerrickServiceID.daemon.machServiceName)
            let remote = NSXPCInterface(with: DerrickDaemonServiceXPC.self)
            // Allow NSXPCListenerEndpoint on peer install / fetch selectors:
            let endpointClasses = NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>
            remote.setClasses(
                endpointClasses,
                for: #selector(DerrickDaemonServiceXPC.peerListenerEndpoint(authJSON:withReply:)),
                argumentIndex: 0,
                ofReply: true
            )
            remote.setClasses(
                endpointClasses,
                for: #selector(DerrickDaemonServiceXPC.setMCPServicePeerEndpoint(_:authJSON:withReply:)),
                argumentIndex: 0,
                ofReply: false
            )
            remote.setClasses(
                endpointClasses,
                for: #selector(DerrickDaemonServiceXPC.setJobServicePeerEndpoint(_:authJSON:withReply:)),
                argumentIndex: 0,
                ofReply: false
            )
            remote.setClasses(
                endpointClasses,
                for: #selector(DerrickDaemonServiceXPC.setDockerHelperPeerEndpoint(_:authJSON:withReply:)),
                argumentIndex: 0,
                ofReply: false
            )
            conn.remoteObjectInterface = remote
            conn.exportedInterface = NSXPCInterface(with: AgentServiceClientSinkXPC.self)
            conn.exportedObject = sink
            do {
                try XPCPeerAuthentication.apply(
                    requirement: XPCPeerAuthentication.requirementString(
                        allowedPeerIdentifiers: [DerrickServiceID.daemon.rawValue]
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
                debugLog("AgentService NSXPCConnection resumed for daemon mach=\(DerrickServiceID.daemon.machServiceName)")
            }
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in
                debugLog("AgentService proxy error: \(error.localizedDescription)")
            }
        }) as? DerrickDaemonServiceXPC else {
            throw AgentServiceClientError.unavailable
        }
        return proxy
    }

    private nonisolated func invalidate() {
        lock.lock()
        let hasActiveTurn = sink.hasForegroundTurns
        let conn = connection
        // Always drop the dead handle so the next ensureReadyForTurn reconnects.
        // Do not call invalidate() again while a turn is in flight — that races the reply path.
        connection = nil
        isReady = false
        lock.unlock()
        if hasActiveTurn {
            fputs("[AgentServiceClient] cleared dead XPC handle (foreground turn still active)\n", stderr)
            return
        }
        conn?.invalidate()
    }

    private func invoke<T: Sendable>(
        timeout nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw AgentServiceClientError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AgentServiceClientError.timeout }
            return first
        }
    }
}

public enum AgentServiceClientError: Error, LocalizedError {
    case unavailable
    case bootstrapFailed(String)
    case turnFailed(String)
    case rejected(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "AgentService is unavailable. Check service_logs and that AgentService.xpc is embedded."
        case .bootstrapFailed(let message):
            return "AgentService bootstrap failed: \(message)"
        case .turnFailed(let message):
            return "AgentService turn failed: \(message)"
        case .rejected(let message):
            return message
        case .timeout:
            return "AgentService XPC call timed out."
        }
    }
}
