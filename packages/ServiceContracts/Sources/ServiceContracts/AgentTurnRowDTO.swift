import Foundation

/// Durable turn row for orchestration audit and recovery.
public enum AgentTurnStatus: String, Codable, Sendable, Hashable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct AgentTurnRowDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let applicationName: String
    public let sessionID: String
    public let agentID: String
    public let correlationID: String?
    public let envelopeKind: String
    public var status: AgentTurnStatus
    public let promptPreview: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        applicationName: String,
        sessionID: String,
        agentID: String,
        correlationID: String? = nil,
        envelopeKind: String,
        status: AgentTurnStatus = .queued,
        promptPreview: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.applicationName = applicationName
        self.sessionID = sessionID
        self.agentID = agentID
        self.correlationID = correlationID
        self.envelopeKind = envelopeKind
        self.status = status
        self.promptPreview = promptPreview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
