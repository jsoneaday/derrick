import Foundation

/// Content Policy evaluator. Returns the canonical `GuardrailDecision`.
public protocol PolicyEvaluator: Sendable {
    func evaluateAssistantChunk(_ event: AssistantChunkEvent) async throws -> GuardrailDecision
    func evaluateAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> GuardrailDecision
}

/// Result of content policy interception (preserves deny reasons for UI).
public enum AssistantContentInterceptResult: Equatable, Sendable {
    case allowed(String)
    case denied(reason: String)
    /// Policy requires user approval before this content is accepted as final.
    case confirm(content: String, requiredFields: [String])
}

public protocol PolicyInterceptor: Sendable {
    func interceptAssistantChunk(_ event: AssistantChunkEvent) async throws -> AssistantContentInterceptResult
    func interceptAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> AssistantContentInterceptResult
}

/// Historical alias — prefer `GuardrailDecision`.
@available(*, deprecated, renamed: "GuardrailDecision")
public typealias PolicyDecisionOutcome = GuardrailDecision
