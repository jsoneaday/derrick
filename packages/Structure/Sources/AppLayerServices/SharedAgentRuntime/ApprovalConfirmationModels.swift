import Foundation

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
