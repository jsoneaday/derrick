import Foundation

public enum PolicyDecisionOutcome: Equatable, Sendable {
    case allow
    case deny(reason: String)
    case confirm(requiredFields: [String])
    case redact(pattern: String, replacement: String)
}

public protocol PolicyEvaluator: Sendable {
    func evaluateAssistantChunk(_ event: AssistantChunkEvent) async throws -> PolicyDecisionOutcome
    func evaluateAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> PolicyDecisionOutcome
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
