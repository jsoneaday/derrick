import Foundation
import DockerRunnerXPC
import ServiceContracts

/// JobService → AgentService: signed startTurn with a no-op reverse sink (no UI chat stream).
/// Job wakes use `delivery: .jobResultModal` and an isolated `job-` session.
final class JobAgentClient: @unchecked Sendable {
    static let shared = JobAgentClient()

    static let defaultModelJSON = Data(#"{"openai":{"_0":"gpt-5.6-luna"}}"#.utf8)

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var peerEndpoint: NSXPCListenerEndpoint?
    private let sink = JobAgentSink()
    private let callTimeoutNanoseconds: UInt64 = 120_000_000_000

    private init() {}

    var hasPeerEndpoint: Bool {
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
        JobServiceMeshState.shared.markAgentPeerReady()
        fputs("[JobAgentClient] peer endpoint installed\n", stderr)
    }

    func verifyPeerMesh() async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let report: ServiceHealthReport = try await invoke(timeout: 15_000_000_000) {
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
        guard report.status == .ok else {
            throw JobServiceError.stepFailed(report.detail ?? "Agent health not ok")
        }
        fputs("[JobAgentClient] peer mesh verified status=\(report.status.rawValue)\n", stderr)
    }

    /// Start a job-isolated turn. AgentService collects completion and presents a job-result modal/notification.
    func wakeAgent(payload: JobWakeAgentPayload) async throws -> AgentTurnAccepted {
        let modelJSON = payload.modelJSON ?? Self.defaultModelJSON
        let apiKey = payload.apiKey ?? ""
        let request = AgentTurnRequest(
            sessionID: payload.sessionID,
            prompt: payload.prompt,
            apiKey: apiKey,
            modelJSON: modelJSON,
            delivery: .jobResultModal,
            jobID: payload.jobID,
            parentSessionID: payload.parentSessionID
        )
        nonisolated(unsafe) let proxy = try remoteProxy()
        nonisolated(unsafe) let payloadData = try AgentServiceXPCCodec.encodeSignedTurnRequest(request) as NSData
        return try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AgentTurnAccepted, Error>) in
                proxy.startTurn(requestJSON: payloadData) { data in
                    do {
                        cont.resume(returning: try AgentServiceXPCCodec.decodeTurnAccepted(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func remoteProxy() throws -> AgentServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            guard let endpoint = peerEndpoint else {
                throw JobServiceError.stepFailed(
                    "AgentService peer endpoint missing (UI must hand off Agent peer to JobService)"
                )
            }
            let conn = NSXPCConnection(listenerEndpoint: endpoint)
            let remote = NSXPCInterface(with: AgentServiceXPC.self)
            let endpointClasses = NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>
            remote.setClasses(
                endpointClasses,
                for: #selector(AgentServiceXPC.setMCPServicePeerEndpoint(_:authJSON:withReply:)),
                argumentIndex: 0,
                ofReply: false
            )
            remote.setClasses(
                endpointClasses,
                for: #selector(AgentServiceXPC.setJobServicePeerEndpoint(_:authJSON:withReply:)),
                argumentIndex: 0,
                ofReply: false
            )
            conn.remoteObjectInterface = remote
            conn.exportedInterface = NSXPCInterface(with: AgentServiceClientSinkXPC.self)
            conn.exportedObject = sink
            conn.interruptionHandler = { [weak self] in self?.invalidate() }
            conn.invalidationHandler = { [weak self] in self?.invalidate() }
            conn.resume()
            connection = conn
            fputs("[JobAgentClient] peer connected\n", stderr)
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("[JobAgentClient] proxy error: \(error.localizedDescription)\n", stderr)
            self?.invalidate()
        }) as? AgentServiceXPC else {
            throw JobServiceError.stepFailed("AgentService proxy unavailable")
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
                throw JobServiceError.stepFailed("AgentService XPC call timed out")
            }
            guard let first = try await group.next() else {
                throw JobServiceError.stepFailed("AgentService XPC call timed out")
            }
            group.cancelAll()
            return first
        }
    }
}

/// Silent sink: job turns must not paint chat; AgentService presents job results to UI primary sink.
private final class JobAgentSink: NSObject, AgentServiceClientSinkXPC, @unchecked Sendable {
    func appendServiceLogLine(_ line: String) {
        fputs("[JobAgentSink] \(line)\n", stderr)
    }

    func turnDidEmitChunk(_ turnID: String, chunkJSON: NSData) {}

    func turnDidFinish(_ turnID: String, errorJSON: NSData) {
        if errorJSON.length > 0 {
            fputs("[JobAgentSink] turn \(turnID) finished with error payload\n", stderr)
        } else {
            fputs("[JobAgentSink] turn \(turnID) finished ok\n", stderr)
        }
    }

    func requestApproval(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        reply(Data() as NSData)
    }

    func requestNetworkAccess(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        reply(Data() as NSData)
    }

    func presentJobResult(_ resultJSON: NSData) {
        // JobService is not the UI; ignore.
    }
}
