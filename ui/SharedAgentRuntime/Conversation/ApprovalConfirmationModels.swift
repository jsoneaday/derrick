import Foundation
import MemorySystem

public struct ApprovalConfirmationRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public let sessionID: String
    public let toolName: String
    public let argumentsJSON: String
    public let requiredFields: [String]
    public let createdAt: Date

    public init(
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

public enum ApprovalConfirmationDecision: Equatable, Sendable {
    case approved(editedArgumentsJSON: String, actor: String?)
    case cancelled(actor: String?)
}

/// Not `@MainActor`: AgentService runs confirms off the main actor over XPC.
/// UI presenters may hop to MainActor internally.
public protocol ApprovalConfirmationPresenting: Sendable {
    func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision
}

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
