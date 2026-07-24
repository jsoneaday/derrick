import SwiftUI
import Combine
import AppEvents
import PolicyUserInteraction

@MainActor
final class ApprovalPresentationModel: ObservableObject, ApprovalConfirmationPresenting {
    func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision {
        let preview: String
        if request.argumentsJSON.count > 1200 {
            preview = String(request.argumentsJSON.prefix(1200)) + "…"
        } else {
            preview = request.argumentsJSON
        }

        let event = PolicyUserEventFactory.approvalRequired(
            summary: "The agent wants to run “\(request.toolName)”. Review the request and choose Allow or Deny.",
            detail: request.requiredFields.isEmpty
                ? nil
                : "Required fields: \(request.requiredFields.joined(separator: ", "))",
            toolName: request.toolName,
            payloadPreview: preview,
            correlationId: request.sessionID,
            rememberKey: "tool:\(request.toolName)"
        )

        debugLog("[policy-ui] requesting approval for tool=\(request.toolName)")
        let decision = await AppEventBus.shared.initDecision(event)
        switch decision {
        case .approved(let actor):
            return .approved(editedArgumentsJSON: request.argumentsJSON, actor: actor)
        case .denied(let actor):
            return .cancelled(actor: actor)
        case .timedOut:
            debugLog("Approval request expired after timeout.")
            return .cancelled(actor: "system-timeout")
        case .dismissed:
            return .cancelled(actor: "ui-user")
        }
    }
}
