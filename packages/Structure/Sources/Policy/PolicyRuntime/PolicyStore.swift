import Foundation

public struct PolicyRule: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let applicationName: String
    public var name: String
    public let scope: String
    public var matcherJSON: String
    public var outcomeJSON: String
    public var priority: Int
    public var enabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        applicationName: String,
        name: String,
        scope: String,
        matcherJSON: String,
        outcomeJSON: String,
        priority: Int = 100,
        enabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.applicationName = applicationName
        self.name = name
        self.scope = scope
        self.matcherJSON = matcherJSON
        self.outcomeJSON = outcomeJSON
        self.priority = priority
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PolicyApproval: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let applicationName: String
    public let sessionID: String
    public let ruleID: String
    public let requestType: String
    public let requestPayloadJSON: String
    public let editedPayloadJSON: String?
    public let decision: String
    public let actor: String?
    public let createdAt: Date
    public let acedAt: Date?

    public init(
        id: String = UUID().uuidString,
        applicationName: String,
        sessionID: String,
        ruleID: String,
        requestType: String,
        requestPayloadJSON: String,
        editedPayloadJSON: String? = nil,
        decision: String,
        actor: String? = nil,
        createdAt: Date = .now,
        acedAt: Date? = nil
    ) {
        self.id = id
        self.applicationName = applicationName
        self.sessionID = sessionID
        self.ruleID = ruleID
        self.requestType = requestType
        self.requestPayloadJSON = requestPayloadJSON
        self.editedPayloadJSON = editedPayloadJSON
        self.decision = decision
        self.actor = actor
        self.createdAt = createdAt
        self.acedAt = acedAt
    }
}

public struct PolicyAuditLogEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let applicationName: String
    public let sessionID: String
    public let eventType: String
    public let scope: String
    public let requestJSON: String
    public let decision: String
    public let reason: String?
    public let actor: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        applicationName: String,
        sessionID: String,
        eventType: String,
        scope: String,
        requestJSON: String,
        decision: String,
        reason: String? = nil,
        actor: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.applicationName = applicationName
        self.sessionID = sessionID
        self.eventType = eventType
        self.scope = scope
        self.requestJSON = requestJSON
        self.decision = decision
        self.reason = reason
        self.actor = actor
        self.createdAt = createdAt
    }
}

public protocol PolicyStore: Sendable {
    func loadRules(applicationName: String, scope: String) async throws -> [PolicyRule]
    func saveRule(_ rule: PolicyRule) async throws
    func saveApproval(_ approval: PolicyApproval) async throws
    func loadApprovals(sessionID: String, limit: Int) async throws -> [PolicyApproval]
    func logAuditEntry(_ entry: PolicyAuditLogEntry) async throws
    func auditLog(sessionID: String, limit: Int, page: Int) async throws -> [PolicyAuditLogEntry]
}
