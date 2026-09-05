import Foundation
import MemorySystem
import Structure

public struct ClosureApprovalConfirmationPresenter: ApprovalConfirmationPresenting {
    private let handler: @Sendable (ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision

    public init(handler: @escaping @Sendable (ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision) {
        self.handler = handler
    }

    public func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision {
        await handler(request)
    }
}

extension PolicyApproval {
    public static func fromApprovalDecision(
        applicationName: String,
        sessionID: String,
        ruleID: String = "runtime-confirmation",
        requestType: String = "tool_invocation",
        requestPayloadJSON: String,
        decision: ApprovalConfirmationDecision
    ) -> PolicyApproval {
        switch decision {
        case .approved(let editedArgumentsJSON, let actor):
            return PolicyApproval(
                applicationName: applicationName,
                sessionID: sessionID,
                ruleID: ruleID,
                requestType: requestType,
                requestPayloadJSON: requestPayloadJSON,
                editedPayloadJSON: editedArgumentsJSON,
                decision: "approved",
                actor: actor,
                createdAt: .now,
                acedAt: .now
            )
        case .cancelled(let actor):
            return PolicyApproval(
                applicationName: applicationName,
                sessionID: sessionID,
                ruleID: ruleID,
                requestType: requestType,
                requestPayloadJSON: requestPayloadJSON,
                editedPayloadJSON: nil,
                decision: "cancelled",
                actor: actor,
                createdAt: .now,
                acedAt: .now
            )
        }
    }
}
