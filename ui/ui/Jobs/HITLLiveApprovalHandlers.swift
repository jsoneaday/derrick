import AppEvents
import Foundation
import PolicyUserInteraction
import ServiceContracts

/// Live-chat HITL: modal via PolicyEventPresenter (never notifications while UI is connected).
@MainActor
enum HITLLiveApprovalHandlers {
    static func wireAgentServiceClient() {
        AgentServiceClient.shared.setApprovalHandler { request in
            await presentToolApproval(request)
        }
        AgentServiceClient.shared.setNetworkAccessHandler { request in
            await presentNetworkAccess(request)
        }
        AgentServiceClient.shared.setJobPreflightHandler { request in
            await JobPreflightApprovalPresenter.shared.present(request)
        }
        AgentServiceClient.shared.setPolicyDecisionHandler { request in
            await presentPolicyDecision(request)
        }
    }

    private static func presentPolicyDecision(
        _ request: AgentPolicyDecisionRequestDTO
    ) async -> AgentPolicyDecisionDTO {
        let kind = PolicyEventKind(rawValue: request.kind) ?? .usageLimitRequest
        let source = PolicyEventSource(rawValue: request.source) ?? .usageLimits
        let eventID = UUID(uuidString: request.requestID) ?? UUID()
        let event = PolicyUserEvent(
            id: eventID,
            correlationId: request.correlationId,
            kind: kind,
            source: source,
            title: request.title,
            summary: request.summary,
            detail: request.detail,
            toolName: request.toolName,
            payloadPreview: request.payloadPreview,
            rememberKey: request.rememberKey
        )
        let decision = await AppEventBus.shared.initDecision(event)
        let decisionString: String
        let actor: String?
        switch decision {
        case .approved(let a):
            decisionString = "approved"
            actor = a
        case .approvedOnce(let a):
            decisionString = "approvedOnce"
            actor = a
        case .approvedPermanently(let a):
            decisionString = "approvedPermanently"
            actor = a
        case .denied(let a):
            decisionString = "denied"
            actor = a
        case .timedOut:
            decisionString = "timedOut"
            actor = nil
        case .dismissed:
            decisionString = "dismissed"
            actor = nil
        }
        return AgentPolicyDecisionDTO(
            requestID: request.requestID,
            decision: decisionString,
            actor: actor
        )
    }

    private static func presentToolApproval(_ request: AgentApprovalRequestDTO) async -> AgentApprovalDecisionDTO {
        let preview = request.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String
        if preview.isEmpty {
            summary = "Allow the agent to run “\(request.toolName)”?"
        } else {
            let capped = preview.count > 240 ? String(preview.prefix(240)) + "…" : preview
            summary = "Allow “\(request.toolName)”?\n\n\(capped)"
        }
        let event = PolicyUserEventFactory.approvalRequired(
            summary: summary,
            toolName: request.toolName,
            payloadPreview: preview.isEmpty ? nil : preview,
            correlationId: request.approvalID
        )
        let decision = await AppEventBus.shared.initDecision(event)
        switch decision {
        case .approved, .approvedOnce:
            return AgentApprovalDecisionDTO(
                approvalID: request.approvalID,
                approved: true,
                editedArgumentsJSON: request.argumentsJSON,
                actor: "ui-modal-allow"
            )
        case .approvedPermanently:
            return AgentApprovalDecisionDTO(
                approvalID: request.approvalID,
                approved: true,
                editedArgumentsJSON: request.argumentsJSON,
                actor: "ui-modal-allow-always"
            )
        case .timedOut:
            return AgentApprovalDecisionDTO(
                approvalID: request.approvalID,
                approved: false,
                editedArgumentsJSON: request.argumentsJSON,
                actor: "ui-modal-timeout"
            )
        case .dismissed, .denied:
            return AgentApprovalDecisionDTO(
                approvalID: request.approvalID,
                approved: false,
                editedArgumentsJSON: request.argumentsJSON,
                actor: "ui-modal-deny"
            )
        }
    }

    private static func presentNetworkAccess(_ request: AgentNetworkAccessRequestDTO) async -> AgentNetworkAccessDecisionDTO {
        let event = PolicyUserEventFactory.egressAccessRequest(
            host: request.host,
            toolName: request.toolName,
            correlationId: request.requestID
        )
        let decision = await AppEventBus.shared.initDecision(event)
        switch decision {
        case .approvedOnce(let actor):
            await EgressAllowlistService.shared.applyUserNetworkDecision(
                host: request.host,
                decision: .approvedOnce(actor: actor)
            )
            return AgentNetworkAccessDecisionDTO(
                requestID: request.requestID,
                decision: "once",
                actor: actor ?? "ui-modal-once"
            )
        case .approvedPermanently(let actor):
            await EgressAllowlistService.shared.applyUserNetworkDecision(
                host: request.host,
                decision: .approvedPermanently(actor: actor)
            )
            return AgentNetworkAccessDecisionDTO(
                requestID: request.requestID,
                decision: "always",
                actor: actor ?? "ui-modal-always"
            )
        case .timedOut:
            return AgentNetworkAccessDecisionDTO(
                requestID: request.requestID,
                decision: "timeout",
                actor: "ui-modal-timeout"
            )
        case .dismissed:
            return AgentNetworkAccessDecisionDTO(
                requestID: request.requestID,
                decision: "dismissed",
                actor: "ui-modal-dismissed"
            )
        case .approved, .denied:
            return AgentNetworkAccessDecisionDTO(
                requestID: request.requestID,
                decision: "deny",
                actor: "ui-modal-deny"
            )
        }
    }
}
