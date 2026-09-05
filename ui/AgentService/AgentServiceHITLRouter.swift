import DBRepository
import Foundation
import PolicyUserInteraction
import Structure

/// Routes human-in-the-loop requests between live UI modals and notification delivery.
enum AgentServiceHITLRouter {
    static func shouldUseNotificationPath(sessionID: String, isJobWake: Bool) -> Bool {
        if DerrickUISessionPresence.isInteractiveSessionActive() {
            // Prefer live UI modals; fall back to notifications if the reverse sink is down.
            if AgentServicePrimaryUISink.shared.clientSink(logLabel: "hitl-route") != nil {
                return false
            }
            fputs("[AgentServiceHITL] interactive UI active but sink missing — notification fallback\n", stderr)
            return true
        }
        if isJobWake || JobSessionID.isJobSession(sessionID) {
            return true
        }
        return AgentServicePrimaryUISink.shared.clientSink(logLabel: "hitl-route") == nil
    }

    static func requestNetworkAccess(
        host: String,
        toolName: String,
        turnID: String,
        sessionID: String,
        isJobWake: Bool,
        resolveRepository: @Sendable () async throws -> DBRepository?,
        timeoutSeconds: UInt64 = 300
    ) async -> PolicyUserDecision {
        if shouldUseNotificationPath(sessionID: sessionID, isJobWake: isJobWake) {
            return await XPCRemoteNetworkAccess.prompt(
                host: host,
                toolName: toolName,
                turnID: turnID,
                isJobContext: isJobWake || JobSessionID.isJobSession(sessionID),
                resolveRepository: resolveRepository,
                timeoutSeconds: timeoutSeconds
            )
        }
        return await requestNetworkViaUISink(host: host, toolName: toolName)
    }

    static func requestNetworkViaUISink(host: String, toolName: String) async -> PolicyUserDecision {
        guard let sink = AgentServicePrimaryUISink.shared.clientSink(logLabel: "network")
            ?? AgentServicePrimaryUISink.shared.clientSink(logLabel: "network-retry") else {
            return .denied(actor: "system-no-ui-sink")
        }
        let request = AgentNetworkAccessRequestDTO(host: host, toolName: toolName)
        do {
            let payload = try AgentServiceXPCCodec.encodeSignedNetworkAccessRequest(request)
            nonisolated(unsafe) let capturedSink = sink
            let replyData = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                        capturedSink.requestNetworkAccess(requestJSON: payload as NSData) { reply in
                            continuation.resume(returning: reply as Data)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                    throw CancellationError()
                }
                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return first
            }
            let decision = try AgentServiceXPCCodec.decodeSignedNetworkAccessDecision(replyData)
            return mapNetworkDecision(decision)
        } catch {
            fputs("[AgentServiceHITL] network XPC failed: \(error.localizedDescription)\n", stderr)
            return .denied(actor: "system-xpc-failed")
        }
    }

    static func requestToolApprovalViaUISink(
        request: ApprovalConfirmationRequest,
        turnID: String
    ) async -> ApprovalConfirmationDecision {
        guard let sink = AgentServicePrimaryUISink.shared.clientSink(logLabel: "approval") else {
            return .cancelled(actor: "system-no-ui-sink")
        }
        let dto = AgentApprovalRequestDTO(
            approvalID: request.id,
            turnID: turnID,
            sessionID: request.sessionID,
            toolName: request.toolName,
            argumentsJSON: request.argumentsJSON,
            requiredFields: request.requiredFields
        )
        do {
            let payload = try AgentServiceXPCCodec.encodeSignedApprovalRequest(dto)
            let replyData = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                sink.requestApproval(requestJSON: payload as NSData) { reply in
                    continuation.resume(returning: reply as Data)
                }
            }
            let decision = try AgentServiceXPCCodec.decodeSignedApprovalDecision(replyData)
            if decision.approved {
                return .approved(
                    editedArgumentsJSON: decision.editedArgumentsJSON.isEmpty
                        ? request.argumentsJSON
                        : decision.editedArgumentsJSON,
                    actor: decision.actor.isEmpty ? nil : decision.actor
                )
            }
            return .cancelled(actor: decision.actor.isEmpty ? nil : decision.actor)
        } catch {
            fputs("[AgentServiceHITL] approval XPC failed: \(error.localizedDescription)\n", stderr)
            return .cancelled(actor: "system-xpc-failed")
        }
    }

    private static func mapNetworkDecision(_ dto: AgentNetworkAccessDecisionDTO) -> PolicyUserDecision {
        switch dto.decision.lowercased() {
        case "once":
            return .approvedOnce(actor: dto.actor.isEmpty ? nil : dto.actor)
        case "always":
            return .approvedPermanently(actor: dto.actor.isEmpty ? nil : dto.actor)
        case "timeout":
            return .timedOut
        case "dismissed":
            return .dismissed
        default:
            return .denied(actor: dto.actor.isEmpty ? nil : dto.actor)
        }
    }

    /// Usage limits / content sensitivity / other PolicyUserEvent decisions via UI AppEventBus.
    static func requestPolicyDecisionViaUISink(_ event: PolicyUserEvent) async -> PolicyUserDecision {
        guard let sink = AgentServicePrimaryUISink.shared.clientSink(logLabel: "policy-decision") else {
            fputs("[AgentServiceHITL] policy decision denied: no UI sink kind=\(event.kind.rawValue)\n", stderr)
            return .denied(actor: "system-no-ui-sink")
        }
        let request = AgentPolicyDecisionRequestDTO(
            requestID: event.id.uuidString,
            kind: event.kind.rawValue,
            source: event.source.rawValue,
            title: event.title,
            summary: event.summary,
            detail: event.detail,
            toolName: event.toolName,
            payloadPreview: event.payloadPreview,
            rememberKey: event.rememberKey,
            correlationId: event.correlationId
        )
        do {
            let payload = try AgentServiceXPCCodec.encodeSignedPolicyDecisionRequest(request)
            let replyData = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                sink.requestPolicyDecision(requestJSON: payload as NSData) { reply in
                    continuation.resume(returning: reply as Data)
                }
            }
            let decision = try AgentServiceXPCCodec.decodeSignedPolicyDecisionReply(replyData)
            return mapPolicyDecision(decision)
        } catch {
            fputs("[AgentServiceHITL] policy decision XPC failed: \(error.localizedDescription)\n", stderr)
            return .denied(actor: "system-xpc-failed")
        }
    }

    private static func mapPolicyDecision(_ dto: AgentPolicyDecisionDTO) -> PolicyUserDecision {
        let actor = dto.actor.flatMap { $0.isEmpty ? nil : $0 }
        switch dto.decision.lowercased() {
        case "approved":
            return .approved(actor: actor)
        case "approvedonce", "once":
            return .approvedOnce(actor: actor)
        case "approvedpermanently", "always":
            return .approvedPermanently(actor: actor)
        case "timeout", "timedout":
            return .timedOut
        case "dismissed":
            return .dismissed
        default:
            return .denied(actor: actor ?? "ui-deny")
        }
    }
}

/// Tool approval presenter for AgentService turns.
final class AgentServiceApprovalPresenter: ApprovalConfirmationPresenting, @unchecked Sendable {
    typealias RepositoryResolver = @Sendable () async throws -> DBRepository?

    private let turnID: String
    private let sessionID: String
    private let isJobWake: Bool
    private let resolveRepository: RepositoryResolver
    private let timeoutNanoseconds: UInt64

    init(
        turnID: String,
        sessionID: String,
        isJobWake: Bool,
        timeoutSeconds: UInt64 = 300,
        resolveRepository: @escaping RepositoryResolver
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.isJobWake = isJobWake
        self.timeoutNanoseconds = timeoutSeconds * 1_000_000_000
        self.resolveRepository = resolveRepository
    }

    func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision {
        let isCredentialPrompt = request.toolName == PluginCredentialPrompt.toolName
        if !isCredentialPrompt,
           AgentServiceHITLRouter.shouldUseNotificationPath(sessionID: sessionID, isJobWake: isJobWake) {
            guard let repository = try? await resolveRepository() else {
                return .cancelled(actor: "system-no-repository")
            }
            debugLog("HITL: queue notification approval tool=\(request.toolName) id=\(request.id)")
            return await HITLOfflineApprovalService.awaitDecision(
                request: request,
                turnID: turnID,
                isJobContext: isJobWake || JobSessionID.isJobSession(sessionID),
                repository: repository,
                timeoutNanoseconds: timeoutNanoseconds
            )
        }
        debugLog("HITL: live modal approval tool=\(request.toolName) id=\(request.id)")
        return await AgentServiceHITLRouter.requestToolApprovalViaUISink(request: request, turnID: turnID)
    }
}
