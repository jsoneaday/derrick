import Foundation

public enum PolicyEventSource: String, Sendable, Codable, Equatable {
    case staticValidation
    case llmReviewer
    case egressProxy
    case toolGovernance
    case contentGovernance
    case llmProvider
    /// Privileged helper rejected a process launch (XPC allowlist).
    case xpcValidation
    case usageLimits
    case system
}

public enum PolicyEventKind: String, Sendable, Codable, Equatable {
    /// Informational; user dismisses.
    case notice
    /// Hard failure / deny; user dismisses.
    case failure
    /// Needs explicit approve / deny before waiter continues.
    case approvalRequired
    /// Network host access: Allow once / Always / Deny.
    case networkAccessRequest
    /// Usage limit hit: Stop / Raise for this session.
    case usageLimitRequest
}

public enum PolicyUserDecision: Sendable, Equatable {
    case dismissed
    case approved(actor: String?)
    /// Session-only allow (egress “Allow once”).
    case approvedOnce(actor: String?)
    /// Permanent allow (egress “Always”).
    case approvedPermanently(actor: String?)
    case denied(actor: String?)
    case timedOut
}

/// User-facing policy interaction (notify or request approval).
public struct PolicyUserEvent: DecisionRequestingEvent, Equatable {
    public typealias Decision = PolicyUserDecision

    public let id: UUID
    public let createdAt: Date
    public let priority: EventPriority
    public let correlationId: String?

    public let kind: PolicyEventKind
    public let source: PolicyEventSource
    public let title: String
    public let summary: String
    public let detail: String?
    public let toolName: String?
    public let payloadPreview: String?
    /// Hook for permanent approvals later (unused in v1).
    public let rememberKey: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        priority: EventPriority = .userDecision,
        correlationId: String? = nil,
        kind: PolicyEventKind,
        source: PolicyEventSource,
        title: String,
        summary: String,
        detail: String? = nil,
        toolName: String? = nil,
        payloadPreview: String? = nil,
        rememberKey: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.priority = priority
        self.correlationId = correlationId
        self.kind = kind
        self.source = source
        self.title = title
        self.summary = summary
        self.detail = detail
        self.toolName = toolName
        self.payloadPreview = payloadPreview
        self.rememberKey = rememberKey
    }
}
