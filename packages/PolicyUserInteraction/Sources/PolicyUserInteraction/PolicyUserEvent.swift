import Foundation
import AppEvents

public enum PolicyEventSource: String, Sendable, Codable, Equatable {
    case staticValidation
    case llmReviewer
    case egressProxy
    case toolGovernance
    case llmProvider
    /// Privileged helper rejected a process launch (XPC allowlist).
    case xpcValidation
    case system
}

public enum PolicyEventKind: String, Sendable, Codable, Equatable {
    /// Informational; user dismisses.
    case notice
    /// Hard failure / deny; user dismisses.
    case failure
    /// Needs explicit approve / deny before waiter continues.
    case approvalRequired
}

public enum PolicyUserDecision: Sendable, Equatable {
    case dismissed
    case approved(actor: String?)
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

public enum PolicyUserEventFactory {
    public static func failure(
        source: PolicyEventSource,
        title: String,
        summary: String,
        detail: String? = nil,
        toolName: String? = nil,
        payloadPreview: String? = nil,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        PolicyUserEvent(
            priority: .userDecision,
            correlationId: correlationId,
            kind: .failure,
            source: source,
            title: title,
            summary: summary,
            detail: detail,
            toolName: toolName,
            payloadPreview: payloadPreview
        )
    }

    public static func approvalRequired(
        source: PolicyEventSource = .toolGovernance,
        title: String = "Approval required",
        summary: String,
        detail: String? = nil,
        toolName: String?,
        payloadPreview: String?,
        correlationId: String? = nil,
        rememberKey: String? = nil
    ) -> PolicyUserEvent {
        PolicyUserEvent(
            priority: .userDecision,
            correlationId: correlationId,
            kind: .approvalRequired,
            source: source,
            title: title,
            summary: summary,
            detail: detail,
            toolName: toolName,
            payloadPreview: payloadPreview,
            rememberKey: rememberKey
        )
    }

    public static func staticValidationDenied(
        findings: [String],
        toolName: String = "python_script_exec",
        scriptPreview: String? = nil,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .staticValidation,
            title: "Request blocked",
            summary: findings.first ?? "The request failed static policy checks.",
            detail: findings.joined(separator: "\n"),
            toolName: toolName,
            payloadPreview: scriptPreview,
            correlationId: correlationId
        )
    }

    public static func reviewerDenied(
        summary: String,
        concerns: [String],
        toolName: String = "python_script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .llmReviewer,
            title: "Request denied by security review",
            summary: summary,
            detail: concerns.isEmpty ? nil : concerns.joined(separator: "\n"),
            toolName: toolName,
            correlationId: correlationId
        )
    }

    public static func llmProviderFailure(
        title: String,
        message: String,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .llmProvider,
            title: title,
            summary: message,
            correlationId: correlationId
        )
    }

    public static func xpcValidationFailure(
        message: String,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .xpcValidation,
            title: "Docker helper rejected request",
            summary: message,
            detail: "The privileged helper blocked a host process that is not on the allowlist.",
            correlationId: correlationId
        )
    }
}
