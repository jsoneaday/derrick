import Foundation

/// Tool (or content) approval request from AgentService → UI.
public struct AgentApprovalRequestDTO: Codable, Sendable, Hashable {
    public let approvalID: String
    public let turnID: String
    public let sessionID: String
    public let toolName: String
    public let argumentsJSON: String
    public let requiredFields: [String]

    public init(
        approvalID: String = UUID().uuidString,
        turnID: String = "",
        sessionID: String,
        toolName: String,
        argumentsJSON: String,
        requiredFields: [String] = []
    ) {
        self.approvalID = approvalID
        self.turnID = turnID
        self.sessionID = sessionID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.requiredFields = requiredFields
    }
}

/// UI decision returned on the reverse XPC reply.
public struct AgentApprovalDecisionDTO: Codable, Sendable, Hashable {
    public let approvalID: String
    /// true = allow tool; false = deny/cancel.
    public let approved: Bool
    /// Arguments to use if approved (may match original).
    public let editedArgumentsJSON: String
    /// Who decided (user, system-timeout, …). Empty if unknown.
    public let actor: String

    public init(
        approvalID: String,
        approved: Bool,
        editedArgumentsJSON: String = "",
        actor: String = ""
    ) {
        self.approvalID = approvalID
        self.approved = approved
        self.editedArgumentsJSON = editedArgumentsJSON
        self.actor = actor
    }
}
