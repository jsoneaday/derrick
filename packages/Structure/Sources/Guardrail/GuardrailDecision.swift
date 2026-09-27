import Foundation

/// Canonical control-plane decision. Every `*Evaluating` type returns this; every `*Applying` type consumes it.
public enum GuardrailDecision: Hashable, Sendable {
    case allow
    case deny(reason: String)
    case confirmHITL(GuardrailHITLRequest)
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
}
