import Foundation

/// Canonical control-plane decision. Every Policy evaluator maps to this.
public enum GuardrailDecision: Hashable, Sendable {
    case allow
    case deny(reason: String)
    /// Require a human gate before proceeding.
    case confirmHITL(GuardrailHITLRequest)
    /// Require a sequenced workflow before / instead of the proposed action.
    case requireWorkflow(WorkflowKind)
    case redactContent(pattern: String, replacement: String)
    case redactArgument(argumentKey: String, pattern: String, replacement: String)

    public var isAllow: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// HITL details for a `confirmHITL` decision.
public struct GuardrailHITLRequest: Hashable, Sendable {
    public let requiredFields: [String]
    public let title: String?
    public let message: String?

    public init(
        requiredFields: [String] = ["user_approval"],
        title: String? = nil,
        message: String? = nil
    ) {
        self.requiredFields = requiredFields
        self.title = title
        self.message = message
    }

    public init(_ confirmation: PolicyConfirmationRequest) {
        self.requiredFields = ["user_approval"]
        self.title = confirmation.title
        self.message = confirmation.message
    }
}

/// Something Policy can evaluate into a `GuardrailDecision`.
public protocol GuardrailEvaluating: Sendable {
    func guardrailDecision() async throws -> GuardrailDecision
}
