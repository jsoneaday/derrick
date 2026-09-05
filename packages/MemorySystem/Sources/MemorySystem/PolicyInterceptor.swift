import Foundation
import Structure

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
            // Streaming chunks: never modal mid-token. Completion path enforces confirm.
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
        case .confirm(let requiredFields):
            return .confirm(content: event.fullCompletion, requiredFields: requiredFields)
        }
    }
}
