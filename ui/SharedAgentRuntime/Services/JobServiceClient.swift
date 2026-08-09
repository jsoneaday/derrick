import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Client for JobService (create/cancel/list jobs + ensure-up).
///
/// System roles:
/// - **UI process**: `serviceName:` launches Application XPC; used for ensure-up + peer endpoint fetch.
/// - **AgentService process**: connects with a peer `NSXPCListenerEndpoint` installed via handoff.
public final class JobServiceClient: @unchecked Sendable {
    public static let shared = JobServiceClient()

    private let serviceName = DerrickServiceID.job.xpcServiceName
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var peerEndpoint: NSXPCListenerEndpoint?
    private var isReady = false
    private let callTimeoutNanoseconds: UInt64 = 15_000_000_000

    private init() {}

    /// Install peer endpoint in AgentService. Does not prove connectivity — use `verifyPeerMesh()`.
    public func installPeerEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        lock.lock()
        peerEndpoint = endpoint
        connection?.invalidate()
        connection = nil
        lock.unlock()
        fputs("[JobServiceClient] peer endpoint installed\n", stderr)
    }

    /// AgentService: after install, prove health works over the peer link.
    public func verifyPeerMesh() async throws {
        if DerrickProcessRole.isDaemon {
            fputs("[JobServiceClient] in-process Job ready (daemon)\n", stderr)
            return
        }
        nonisolated(unsafe) let proxy = try remoteProxy()
        let report: ServiceHealthReport = try await invoke(timeout: callTimeoutNanoseconds) {
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
        guard report.status == .ok else {
            throw JobServiceClientError.meshUnverified(report.detail ?? "health not ok")
        }
        fputs("[JobServiceClient] peer mesh verified status=\(report.status.rawValue) pid=\(report.pid)\n", stderr)
    }

    /// UI host: fetch anonymous peer endpoint from JobService for Agent handoff.
    public func fetchPeerListenerEndpoint() async throws -> NSXPCListenerEndpoint {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let auth = try JobServiceXPCCodec.encodeSignedPeerHandoffAuth(
            PeerHandoffAuthDTO(kind: .fetchJobPeer),
            from: .ui,
            to: .job
        ) as NSData
        return try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSXPCListenerEndpoint, Error>) in
                proxy.peerListenerEndpoint(authJSON: auth) { endpoint in
                    cont.resume(returning: endpoint)
                }
            }
        }
    }

    /// UI host: install MCPService peer into JobService (Job→MCP tool exec).
    public func setMCPServicePeerEndpoint(_ endpoint: NSXPCListenerEndpoint) async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let auth = try JobServiceXPCCodec.encodeSignedPeerHandoffAuth(
            PeerHandoffAuthDTO(kind: .installMCPPeerToJob),
            from: .ui,
            to: .job
        ) as NSData
        try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.setMCPServicePeerEndpoint(endpoint, authJSON: auth) { data in
                    do {
                        let ack = try JobServiceXPCCodec.decodeSignedAck(data as Data, expectedTo: .ui)
                        if ack.ok { cont.resume() }
                        else {
                            cont.resume(
                                throwing: JobServiceClientError.meshUnverified(
                                    ack.message.isEmpty ? "Job→MCP mesh failed" : ack.message
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
            debugLog("JobService MCPService peer endpoint handoff ok")
        }
    }

    /// UI host: install AgentService peer into JobService (Job→Agent wake).
    public func setAgentServicePeerEndpoint(_ endpoint: NSXPCListenerEndpoint) async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let auth = try JobServiceXPCCodec.encodeSignedPeerHandoffAuth(
            PeerHandoffAuthDTO(kind: .installAgentPeer),
            from: .ui,
            to: .job
        ) as NSData
        try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.setAgentServicePeerEndpoint(endpoint, authJSON: auth) { data in
                    do {
                        let ack = try JobServiceXPCCodec.decodeSignedAck(data as Data, expectedTo: .ui)
                        if ack.ok { cont.resume() }
                        else {
                            cont.resume(
                                throwing: JobServiceClientError.meshUnverified(
                                    ack.message.isEmpty ? "Job→Agent mesh failed" : ack.message
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
            debugLog("JobService AgentService peer endpoint handoff ok")
        }
    }

    public func ensureUpAndHealth(retries: Int = 3) async throws -> ServiceHealthReport {
        if DerrickProcessRole.isDaemon {
            return ServiceHealthReport(service: .job, status: .ok, detail: "in-process (daemon)")
        }
        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            do {
                nonisolated(unsafe) let proxy = try remoteProxy()
                let boot: DerrickDaemonBootstrapResult = try await invoke(timeout: callTimeoutNanoseconds) {
                    try await withCheckedThrowingContinuation { cont in
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
                        "Daemon/Job bootstrap: ok=\(boot.ok) path=\(boot.databasePath ?? "?") modules=\(boot.modules) msg=\(boot.message)"
                    )
                }
                guard boot.ok else {
                    throw JobServiceClientError.bootstrapFailed(boot.message)
                }
                let report: ServiceHealthReport = try await invoke(timeout: callTimeoutNanoseconds) {
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
                await MainActor.run {
                    debugLog(
                        "JobService health: status=\(report.status.rawValue) pid=\(report.pid) detail=\(report.detail ?? "")"
                    )
                }
                markReady()
                return report
            } catch {
                lastError = error
                await MainActor.run {
                    debugLog("JobService ensure-up attempt \(attempt + 1) failed: \(error.localizedDescription)")
                }
                invalidate()
                try? await Task.sleep(nanoseconds: UInt64(100_000_000 * (attempt + 1)))
            }
        }
        throw lastError ?? JobServiceClientError.unavailable
    }

    public func createJob(_ request: CreateJobRequest, from: DerrickServiceID = .ui) async throws -> JobRecord {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedCreateJobRequest(request, from: from) as NSData
        let result: CreateJobResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.createJob(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeCreateJobResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok, let job = result.job else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return job
    }

    public func cancelJob(jobID: String, from: DerrickServiceID = .ui) async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedCancelJob(jobID: jobID, from: from) as NSData
        try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.cancelJob(requestJSON: payload) { data in
                    do {
                        let ack = try JobServiceXPCCodec.decodeSignedAck(data as Data, expectedTo: from)
                        if ack.ok { cont.resume() }
                        else { cont.resume(throwing: JobServiceClientError.requestFailed(ack.message)) }
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func getJob(jobID: String, from: DerrickServiceID = .ui) async throws -> JobRecord {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedGetJob(jobID: jobID, from: from) as NSData
        let result: CreateJobResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.getJob(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeCreateJobResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok, let job = result.job else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return job
    }

    public func listJobs(_ request: ListJobsRequest = ListJobsRequest(), from: DerrickServiceID = .ui) async throws -> [JobRecord] {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedListJobs(request, from: from) as NSData
        let result: ListJobsResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.listJobs(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeListJobsResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return result.jobs
    }

    // MARK: - Schedules

    public func createSchedule(
        _ request: CreateScheduleRequest,
        from: DerrickServiceID = .ui
    ) async throws -> JobScheduleRecord {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedCreateSchedule(request, from: from) as NSData
        let result: ScheduleResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.createSchedule(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeScheduleResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok, let schedule = result.schedule else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return schedule
    }

    public func updateSchedule(
        _ request: UpdateScheduleRequest,
        from: DerrickServiceID = .ui
    ) async throws -> JobScheduleRecord {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedUpdateSchedule(request, from: from) as NSData
        let result: ScheduleResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.updateSchedule(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeScheduleResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok, let schedule = result.schedule else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return schedule
    }

    public func setScheduleEnabled(
        scheduleID: String,
        enabled: Bool,
        from: DerrickServiceID = .ui
    ) async throws -> JobScheduleRecord {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedSetScheduleEnabled(
            SetScheduleEnabledRequest(scheduleID: scheduleID, enabled: enabled),
            from: from
        ) as NSData
        let result: ScheduleResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.setScheduleEnabled(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeScheduleResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok, let schedule = result.schedule else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return schedule
    }

    public func deleteSchedule(scheduleID: String, from: DerrickServiceID = .ui) async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedDeleteSchedule(scheduleID: scheduleID, from: from) as NSData
        try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.deleteSchedule(requestJSON: payload) { data in
                    do {
                        let ack = try JobServiceXPCCodec.decodeSignedAck(data as Data, expectedTo: from)
                        if ack.ok { cont.resume() }
                        else { cont.resume(throwing: JobServiceClientError.requestFailed(ack.message)) }
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func getSchedule(scheduleID: String, from: DerrickServiceID = .ui) async throws -> JobScheduleRecord {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedGetSchedule(scheduleID: scheduleID, from: from) as NSData
        let result: ScheduleResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.getSchedule(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeScheduleResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok, let schedule = result.schedule else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return schedule
    }

    public func listSchedules(
        _ request: ListSchedulesRequest = ListSchedulesRequest(),
        from: DerrickServiceID = .ui
    ) async throws -> [JobScheduleRecord] {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedListSchedules(request, from: from) as NSData
        let result: ListSchedulesResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.listSchedules(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeListSchedulesResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return result.schedules
    }

    // MARK: - Connection

    private func markReady() {
        lock.lock()
        isReady = true
        lock.unlock()
    }

    private func remoteProxy() throws -> JobServiceXPC {
        if DerrickProcessRole.isDaemon, let local = InProcessServiceBridges.jobLocalProxy as? JobServiceXPC {
            return local
        }
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            connection = try makeConnection()
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("[JobServiceClient] proxy error: \(error.localizedDescription)\n", stderr)
            self?.invalidate()
        }) as? DerrickDaemonServiceXPC else {
            throw JobServiceClientError.unavailable
        }
        return proxy
    }

    private var isAgentServiceProcess: Bool {
        (Bundle.main.bundleIdentifier ?? "") == DerrickServiceID.agent.rawValue
    }

    private func makeConnection() throws -> NSXPCConnection {
        // Prefer peer endpoint when installed (legacy AgentService mesh).
        if let endpoint = peerEndpoint {
            let conn = NSXPCConnection(listenerEndpoint: endpoint)
            // Anonymous peer: no client code-sign requirement (same as MCPServiceClient).
            conn.remoteObjectInterface = NSXPCInterface(with: JobServiceXPC.self)
            conn.interruptionHandler = { [weak self] in self?.invalidate() }
            conn.invalidationHandler = { [weak self] in self?.invalidate() }
            conn.resume()
            fputs("[JobServiceClient] peer connected via listener endpoint\n", stderr)
            return conn
        }

        // AgentService must not use serviceName (sibling XPC cannot launch JobService).
        if isAgentServiceProcess {
            throw JobServiceClientError.peerEndpointMissing
        }

        // UI host → derrickd Mach service.
        let conn = NSXPCConnection(machServiceName: DerrickServiceID.daemon.machServiceName)
        let remote = NSXPCInterface(with: DerrickDaemonServiceXPC.self)
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
            for: #selector(DerrickDaemonServiceXPC.setAgentServicePeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        conn.remoteObjectInterface = remote
        do {
            try XPCPeerAuthentication.apply(
                requirement: XPCPeerAuthentication.requirementString(
                    allowedPeerIdentifiers: [DerrickServiceID.daemon.rawValue]
                ),
                to: conn
            )
        } catch {
            fputs("[JobServiceClient] code-sign soft-fail: \(error.localizedDescription)\n", stderr)
        }
        conn.interruptionHandler = { [weak self] in self?.invalidate() }
        conn.invalidationHandler = { [weak self] in self?.invalidate() }
        conn.resume()
        fputs(
            "[JobServiceClient] host connected daemon mach=\(DerrickServiceID.daemon.machServiceName)\n",
            stderr
        )
        return conn
    }

    private func invalidate() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        isReady = false
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
                throw JobServiceClientError.timeout
            }
            guard let first = try await group.next() else { throw JobServiceClientError.timeout }
            group.cancelAll()
            return first
        }
    }
}

public enum JobServiceClientError: Error, LocalizedError {
    case unavailable
    case bootstrapFailed(String)
    case requestFailed(String)
    case timeout
    case peerEndpointMissing
    case meshUnverified(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "JobService is unavailable."
        case .bootstrapFailed(let m): return "JobService bootstrap failed: \(m)"
        case .requestFailed(let m): return "JobService request failed: \(m)"
        case .timeout: return "JobService XPC call timed out."
        case .peerEndpointMissing:
            return "JobService peer endpoint not installed (UI handoff required for AgentService)."
        case .meshUnverified(let m):
            return "Agent→JobService mesh failed verification: \(m)"
        }
    }
}
