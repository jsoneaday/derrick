import Foundation

public enum PendingHITLApprovalStatus: String, Sendable {
    case pending
    case approved
    case cancelled
    case timeout
}

public struct PendingHITLApprovalRow: Sendable, Hashable, Identifiable {
    public let id: String
    public let turnID: String
    public let sessionID: String
    public let toolName: String
    public let argumentsJSON: String
    public let requiredFieldsJSON: String
    public var status: PendingHITLApprovalStatus
    public var editedArgumentsJSON: String?
    public var actor: String?
    public var notifyPosted: Bool
    public let isJobContext: Bool
    public let createdAt: Date
    public var decidedAt: Date?

    public init(
        id: String,
        turnID: String,
        sessionID: String,
        toolName: String,
        argumentsJSON: String,
        requiredFieldsJSON: String,
        status: PendingHITLApprovalStatus = .pending,
        editedArgumentsJSON: String? = nil,
        actor: String? = nil,
        notifyPosted: Bool = false,
        isJobContext: Bool = false,
        createdAt: Date = .now,
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.sessionID = sessionID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.requiredFieldsJSON = requiredFieldsJSON
        self.status = status
        self.editedArgumentsJSON = editedArgumentsJSON
        self.actor = actor
        self.notifyPosted = notifyPosted
        self.isJobContext = isJobContext
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }

    public var requiredFields: [String] {
        guard let data = requiredFieldsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }
}
