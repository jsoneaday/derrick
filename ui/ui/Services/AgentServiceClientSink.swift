import Foundation
import ServiceContracts

/// UI-side reverse XPC object: turn chunks + approval requests from AgentService.
public final class AgentServiceClientSink: NSObject, AgentServiceClientSinkXPC, @unchecked Sendable {
    public struct Handlers: Sendable {
        public var onLog: (@Sendable (String) -> Void)?
        public var onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)?
        public var onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)?
        /// Present approval UI; return decision DTO (runs off main if needed by caller).
        public var onApproval: (@Sendable (AgentApprovalRequestDTO) async -> AgentApprovalDecisionDTO)?
        /// Present network/egress allow UI.
        public var onNetworkAccess: (@Sendable (AgentNetworkAccessRequestDTO) async -> AgentNetworkAccessDecisionDTO)?

        public init(
            onLog: (@Sendable (String) -> Void)? = nil,
            onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)? = nil,
            onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)? = nil,
            onApproval: (@Sendable (AgentApprovalRequestDTO) async -> AgentApprovalDecisionDTO)? = nil,
            onNetworkAccess: (@Sendable (AgentNetworkAccessRequestDTO) async -> AgentNetworkAccessDecisionDTO)? = nil
        ) {
            self.onLog = onLog
            self.onChunk = onChunk
            self.onFinish = onFinish
            self.onApproval = onApproval
            self.onNetworkAccess = onNetworkAccess
        }
    }

    private let lock = NSLock()
    private var handlers: Handlers

    public init(handlers: Handlers = Handlers()) {
        self.handlers = handlers
        super.init()
    }

    /// Replaces turn stream handlers while preserving a previously installed approval handler.
    public func updateTurnHandlers(
        onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)?,
        onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)?
    ) {
        lock.lock()
        handlers.onChunk = onChunk
        handlers.onFinish = onFinish
        lock.unlock()
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
        Task { @MainActor in
            debugLog("[AgentService] \(line)")
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
        let onChunk = handlers.onChunk
        lock.unlock()
        onChunk?(turnID, dto)
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
        let onFinish = handlers.onFinish
        lock.unlock()
        onFinish?(turnID, errorDTO)
    }

    public func requestApproval(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        lock.lock()
        let onApproval = handlers.onApproval
        lock.unlock()

        Task {
            let decisionDTO: AgentApprovalDecisionDTO
            do {
                let request = try AgentServiceXPCCodec.decodeApprovalRequest(data)
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
            let payload = (try? AgentServiceXPCCodec.encodeApprovalDecision(decisionDTO))
                ?? Data(#"{"approvalID":"","approved":false,"editedArgumentsJSON":"","actor":"system-encode-failed"}"#.utf8)
            reply(payload as NSData)
        }
    }

    public func requestNetworkAccess(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        lock.lock()
        let onNetwork = handlers.onNetworkAccess
        lock.unlock()

        Task {
            let decisionDTO: AgentNetworkAccessDecisionDTO
            do {
                let request = try AgentServiceXPCCodec.decodeNetworkAccessRequest(data)
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
            let payload = (try? AgentServiceXPCCodec.encodeNetworkAccessDecision(decisionDTO))
                ?? Data(#"{"requestID":"","decision":"deny","actor":"system-encode-failed"}"#.utf8)
            reply(payload as NSData)
        }
    }
}
