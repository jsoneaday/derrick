import Foundation
import MemorySystem

struct ApprovalConfirmationRequest: Identifiable, Hashable, Sendable {
    let id: String
    let sessionID: String
    let toolName: String
    let argumentsJSON: String
    let requiredFields: [String]
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        sessionID: String,
        toolName: String,
        argumentsJSON: String,
        requiredFields: [String],
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.requiredFields = requiredFields
        self.createdAt = createdAt
    }
}

enum ApprovalConfirmationDecision: Equatable, Sendable {
    case approved(editedArgumentsJSON: String, actor: String?)
    case cancelled(actor: String?)
}

@MainActor
protocol ApprovalConfirmationPresenting: Sendable {
    func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision
}

struct ClosureApprovalConfirmationPresenter: ApprovalConfirmationPresenting {
    private let handler: @Sendable (ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision

    init(handler: @escaping @Sendable (ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision) {
        self.handler = handler
    }

    func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision {
        await handler(request)
    }
}

extension PolicyApproval {
    static func fromApprovalDecision(
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
