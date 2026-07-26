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
}

public protocol PolicyInterceptor: Sendable {
    func interceptAssistantChunk(_ event: AssistantChunkEvent) async throws -> AssistantContentInterceptResult
    func interceptAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> AssistantContentInterceptResult
}

public struct DefaultPolicyInterceptor: PolicyInterceptor {
    private let policy: PolicyEvaluator?

    public init(policy: PolicyEvaluator? = nil) {
        self.policy = policy
    }

    public func interceptAssistantChunk(_ event: AssistantChunkEvent) async throws -> AssistantContentInterceptResult {
        guard let policy else { return .allowed(event.content) }

        let outcome = try await policy.evaluateAssistantChunk(event)
        switch outcome {
        case .allow:
            return .allowed(event.content)
        case .deny(let reason):
            return .denied(reason: reason)
        case .redact(let pattern, let replacement):
            let redacted = event.content.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
            return .allowed(redacted)
        case .confirm:
            // Confirm for content still passes text until dedicated approval UX lands.
            return .allowed(event.content)
        }
    }

    public func interceptAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> AssistantContentInterceptResult {
        guard let policy else { return .allowed(event.fullCompletion) }

        let outcome = try await policy.evaluateAssistantCompletion(event)
        switch outcome {
        case .allow:
            return .allowed(event.fullCompletion)
        case .deny(let reason):
            return .denied(reason: reason)
        case .redact(let pattern, let replacement):
            let redacted = event.fullCompletion.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
            return .allowed(redacted)
        case .confirm:
            return .allowed(event.fullCompletion)
        }
    }
}
