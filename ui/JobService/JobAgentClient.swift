import Foundation
import DockerRunnerXPC
import ServiceContracts

/// JobService → AgentService: signed startTurn with a no-op reverse sink (no UI).
final class JobAgentClient: @unchecked Sendable {
    static let shared = JobAgentClient()

    /// Default helper model JSON for job wakes when payload omits modelJSON.
    /// Matches `LLMModelChoice.openai(.gpt56Luna)` synthesized Codable shape used in tests.
    static let defaultModelJSON = Data(#"{"openai":{"_0":"gpt-5.6-luna"}}"#.utf8)

    private let serviceName = DerrickServiceID.agent.xpcServiceName
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let sink = JobAgentSink()
    private let callTimeoutNanoseconds: UInt64 = 30_000_000_000

    private init() {}

    /// Fire-and-forget agent turn: wait for accept, not for full completion.
    func wakeAgent(payload: JobWakeAgentPayload) async throws -> AgentTurnAccepted {
        let modelJSON = payload.modelJSON ?? Self.defaultModelJSON
        let apiKey = payload.apiKey ?? ""
        let request = AgentTurnRequest(
            sessionID: payload.sessionID,
            prompt: payload.prompt,
            apiKey: apiKey,
            modelJSON: modelJSON
        )
        nonisolated(unsafe) let proxy = try remoteProxy()
        nonisolated(unsafe) let payloadData = try AgentServiceXPCCodec.encodeSignedTurnRequest(request) as NSData
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AgentTurnAccepted, Error>) in
            let box = ResumeOnceBox(cont)
            proxy.startTurn(requestJSON: payloadData) { data in
                do {
                    box.resume(returning: try AgentServiceXPCCodec.decodeTurnAccepted(data as Data))
                } catch {
                    box.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: self.callTimeoutNanoseconds)
                box.resume(throwing: JobServiceError.stepFailed("AgentService startTurn timed out"))
            }
        }
    }

    private func remoteProxy() throws -> AgentServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(serviceName: serviceName)
            let remote = NSXPCInterface(with: AgentServiceXPC.self)
            remote.setClasses(
                NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>,
                for: #selector(AgentServiceXPC.setMCPServicePeerEndpoint(_:authJSON:withReply:)),
                argumentIndex: 0,
                ofReply: false
            )
            conn.remoteObjectInterface = remote
            // Agent expects reverse sink (UI). Provide a silent sink for job-sourced turns.
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
                fputs("[JobAgentClient] code-sign soft-fail: \(error.localizedDescription)\n", stderr)
            }
            conn.interruptionHandler = { [weak self] in self?.invalidate() }
            conn.invalidationHandler = { [weak self] in self?.invalidate() }
            conn.resume()
            connection = conn
            fputs("[JobAgentClient] connected to AgentService\n", stderr)
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
}

private final class ResumeOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<AgentTurnAccepted, Error>?

    init(_ cont: CheckedContinuation<AgentTurnAccepted, Error>) {
        self.cont = cont
    }

    func resume(returning value: AgentTurnAccepted) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}

/// Reverse XPC sink: log only (no UI modals). Approvals/network fail closed.
private final class JobAgentSink: NSObject, AgentServiceClientSinkXPC, @unchecked Sendable {
    func appendServiceLogLine(_ line: String) {
        fputs("[JobAgentClient] [Agent] \(line)\n", stderr)
    }

    func turnDidEmitChunk(_ turnID: String, chunkJSON: NSData) {
        // Intentionally ignored — job wake is fire-and-forget for completion text.
    }

    func turnDidFinish(_ turnID: String, errorJSON: NSData) {
        if errorJSON.length > 0 {
            fputs("[JobAgentClient] turn \(turnID) finished with error payload\n", stderr)
        } else {
            fputs("[JobAgentClient] turn \(turnID) finished ok\n", stderr)
        }
    }

    func requestApproval(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        fputs("[JobAgentClient] approval requested without UI — deny\n", stderr)
        let decision = AgentApprovalDecisionDTO(
            approvalID: "",
            approved: false,
            editedArgumentsJSON: "",
            actor: "job-service-no-ui"
        )
        let data = (try? AgentServiceXPCCodec.encodeSignedApprovalDecision(decision)) ?? Data()
        reply(data as NSData)
    }

    func requestNetworkAccess(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        fputs("[JobAgentClient] network access requested without UI — deny\n", stderr)
        let decision = AgentNetworkAccessDecisionDTO(
            requestID: "",
            decision: "deny",
            actor: "job-service-no-ui"
        )
        let data = (try? AgentServiceXPCCodec.encodeSignedNetworkAccessDecision(decision)) ?? Data()
        reply(data as NSData)
    }
}
