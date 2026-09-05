import Foundation
import Structure
import DBRepository

/// UI-side reverse XPC object: turn chunks + approval requests from AgentService.
public final class AgentServiceClientSink: NSObject, AgentServiceClientSinkXPC, @unchecked Sendable {
    public struct Handlers: Sendable {
        public var onLog: (@Sendable (String) -> Void)?
        public var onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)?
        public var onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)?
        /// Chunks for turns not owned by the active `streamTurn` (e.g. job wakeAgent).
        public var onBackgroundChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)?
        public var onBackgroundFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)?
        /// Present approval UI; return decision DTO (runs off main if needed by caller).
        public var onApproval: (@Sendable (AgentApprovalRequestDTO) async -> AgentApprovalDecisionDTO)?
        /// Present network/egress allow UI.
        public var onNetworkAccess: (@Sendable (AgentNetworkAccessRequestDTO) async -> AgentNetworkAccessDecisionDTO)?
        /// Usage limits / content sensitivity / generic PolicyUserEvent decisions.
        public var onPolicyDecision: (@Sendable (AgentPolicyDecisionRequestDTO) async -> AgentPolicyDecisionDTO)?

        public init(
            onLog: (@Sendable (String) -> Void)? = nil,
            onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)? = nil,
            onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)? = nil,
            onBackgroundChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)? = nil,
            onBackgroundFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)? = nil,
            onApproval: (@Sendable (AgentApprovalRequestDTO) async -> AgentApprovalDecisionDTO)? = nil,
            onNetworkAccess: (@Sendable (AgentNetworkAccessRequestDTO) async -> AgentNetworkAccessDecisionDTO)? = nil,
            onPolicyDecision: (@Sendable (AgentPolicyDecisionRequestDTO) async -> AgentPolicyDecisionDTO)? = nil
        ) {
            self.onLog = onLog
            self.onChunk = onChunk
            self.onFinish = onFinish
            self.onBackgroundChunk = onBackgroundChunk
            self.onBackgroundFinish = onBackgroundFinish
            self.onApproval = onApproval
            self.onNetworkAccess = onNetworkAccess
            self.onPolicyDecision = onPolicyDecision
        }
    }

    private let lock = NSLock()
    private var handlers: Handlers
    /// Turn IDs currently owned by an in-flight `streamTurn` (not background).
    private var foregroundTurnIDs: Set<String> = []

    public init(handlers: Handlers = Handlers()) {
        self.handlers = handlers
        super.init()
    }

    /// Replaces turn stream handlers while preserving approval + background handlers.
    public func updateTurnHandlers(
        onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)?,
        onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)?
    ) {
        lock.lock()
        handlers.onChunk = onChunk
        handlers.onFinish = onFinish
        lock.unlock()
    }

    public func setBackgroundTurnHandlers(
        onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)?,
        onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)?
    ) {
        lock.lock()
        handlers.onBackgroundChunk = onChunk
        handlers.onBackgroundFinish = onFinish
        lock.unlock()
    }

    public func beginForegroundTurn(_ turnID: String) {
        lock.lock()
        foregroundTurnIDs.insert(turnID)
        lock.unlock()
    }

    public func endForegroundTurn(_ turnID: String) {
        lock.lock()
        foregroundTurnIDs.remove(turnID)
        lock.unlock()
    }

    public var hasForegroundTurns: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !foregroundTurnIDs.isEmpty
    }

    public func setApprovalHandler(
        _ onApproval: (@Sendable (AgentApprovalRequestDTO) async -> AgentApprovalDecisionDTO)?
    ) {
        lock.lock()
        handlers.onApproval = onApproval
        lock.unlock()
    }

    public func setNetworkAccessHandler(
        _ onNetworkAccess: (@Sendable (AgentNetworkAccessRequestDTO) async -> AgentNetworkAccessDecisionDTO)?
    ) {
        lock.lock()
        handlers.onNetworkAccess = onNetworkAccess
        lock.unlock()
    }

    public func setPolicyDecisionHandler(
        _ onPolicyDecision: (@Sendable (AgentPolicyDecisionRequestDTO) async -> AgentPolicyDecisionDTO)?
    ) {
        lock.lock()
        handlers.onPolicyDecision = onPolicyDecision
        lock.unlock()
    }

    public func updateHandlers(_ handlers: Handlers) {
        lock.lock()
        self.handlers = handlers
        lock.unlock()
    }

    public func appendServiceLogLine(_ line: String) {
        lock.lock()
        let onLog = handlers.onLog
        lock.unlock()
        onLog?(line)
        Task {
            await ServiceLogRecorder.shared.record(
                service: DerrickServiceID.agent.shortName,
                level: .debug,
                code: "relay",
                message: line,
                echoToStderr: false
            )
        }
    }

    public func turnDidEmitChunk(_ turnID: String, chunkJSON: NSData) {
        guard let dto = try? AgentServiceXPCCodec.decodeTurnChunk(chunkJSON as Data) else {
            Task { @MainActor in
                debugLog("AgentService sink: failed to decode chunk for turn \(turnID)")
            }
            return
        }
        lock.lock()
        let isForeground = foregroundTurnIDs.contains(turnID)
        let onChunk = handlers.onChunk
        let onBackground = handlers.onBackgroundChunk
        lock.unlock()
        if isForeground {
            onChunk?(turnID, dto)
        } else {
            onBackground?(turnID, dto)
        }
    }

    public func turnDidFinish(_ turnID: String, errorJSON: NSData) {
        let payload = errorJSON as Data
        let errorDTO: AgentTurnErrorDTO?
        if payload.isEmpty {
            errorDTO = nil
        } else {
            errorDTO = try? AgentServiceXPCCodec.decodeTurnError(payload)
        }
        Task { @MainActor in
            if let errorDTO {
                debugLog("AgentService sink: turn \(turnID) finished with error: \(errorDTO.message)")
            } else {
                debugLog("AgentService sink: turn \(turnID) finished ok")
            }
        }
        lock.lock()
        let isForeground = foregroundTurnIDs.contains(turnID)
        let onFinish = handlers.onFinish
        let onBackground = handlers.onBackgroundFinish
        lock.unlock()
        if isForeground {
            onFinish?(turnID, errorDTO)
        } else {
            onBackground?(turnID, errorDTO)
        }
    }

    public func requestApproval(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        lock.lock()
        let onApproval = handlers.onApproval
        lock.unlock()

        Task { @MainActor in
            let decisionDTO: AgentApprovalDecisionDTO
            do {
                let request = try AgentServiceXPCCodec.decodeSignedApprovalRequest(data)
                if let onApproval {
                    decisionDTO = await onApproval(request)
                } else {
                    await MainActor.run {
                        debugLog("AgentService sink: approval requested but no UI handler tool=\(request.toolName)")
                    }
                    decisionDTO = AgentApprovalDecisionDTO(
                        approvalID: request.approvalID,
                        approved: false,
                        editedArgumentsJSON: request.argumentsJSON,
                        actor: "system-no-ui-handler"
                    )
                }
            } catch {
                await MainActor.run {
                    debugLog("AgentService sink: approval decode failed: \(error.localizedDescription)")
                }
                decisionDTO = AgentApprovalDecisionDTO(
                    approvalID: "",
                    approved: false,
                    editedArgumentsJSON: "",
                    actor: "system-decode-failed"
                )
            }
            let payload = (try? AgentServiceXPCCodec.encodeSignedApprovalDecision(decisionDTO))
                ?? Data()
            reply(payload as NSData)
        }
    }

    public func requestNetworkAccess(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        lock.lock()
        let onNetwork = handlers.onNetworkAccess
        lock.unlock()

        Task { @MainActor in
            let decisionDTO: AgentNetworkAccessDecisionDTO
            do {
                let request = try AgentServiceXPCCodec.decodeSignedNetworkAccessRequest(data)
                if let onNetwork {
                    decisionDTO = await onNetwork(request)
                } else {
                    await MainActor.run {
                        debugLog("AgentService sink: network access requested but no UI handler host=\(request.host)")
                    }
                    decisionDTO = AgentNetworkAccessDecisionDTO(
                        requestID: request.requestID,
                        decision: "deny",
                        actor: "system-no-ui-handler"
                    )
                }
            } catch {
                await MainActor.run {
                    debugLog("AgentService sink: network request decode failed: \(error.localizedDescription)")
                }
                decisionDTO = AgentNetworkAccessDecisionDTO(
                    requestID: "",
                    decision: "deny",
                    actor: "system-decode-failed"
                )
            }
            let payload = (try? AgentServiceXPCCodec.encodeSignedNetworkAccessDecision(decisionDTO))
                ?? Data()
            reply(payload as NSData)
        }
    }

    public func requestPolicyDecision(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        lock.lock()
        let onPolicyDecision = handlers.onPolicyDecision
        lock.unlock()

        Task { @MainActor in
            let decisionDTO: AgentPolicyDecisionDTO
            do {
                let request = try AgentServiceXPCCodec.decodeSignedPolicyDecisionRequest(data)
                if let onPolicyDecision {
                    decisionDTO = await onPolicyDecision(request)
                } else {
                    await MainActor.run {
                        debugLog("AgentService sink: policy decision requested but no UI handler kind=\(request.kind)")
                    }
                    decisionDTO = AgentPolicyDecisionDTO(
                        requestID: request.requestID,
                        decision: "denied",
                        actor: "system-no-ui-handler"
                    )
                }
            } catch {
                await MainActor.run {
                    debugLog("AgentService sink: policy decision decode failed: \(error.localizedDescription)")
                }
                decisionDTO = AgentPolicyDecisionDTO(
                    requestID: "",
                    decision: "denied",
                    actor: "system-decode-failed"
                )
            }
            let payload = (try? AgentServiceXPCCodec.encodeSignedPolicyDecisionReply(decisionDTO)) ?? Data()
            reply(payload as NSData)
        }
    }
}
