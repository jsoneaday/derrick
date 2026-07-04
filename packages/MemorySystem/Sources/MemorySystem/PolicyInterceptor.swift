import Foundation

public enum PolicyDecisionOutcome: Equatable, Sendable {
    case allow
    case deny(reason: String)
    case confirm(requiredFields: [String])
    case redact(pattern: String, replacement: String)
}

public protocol ResponseContentPolicy: Sendable {
    func evaluateAssistantChunk(_ event: AssistantChunkEvent) async throws -> PolicyDecisionOutcome
    func evaluateAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> PolicyDecisionOutcome
}

public protocol PolicyInterceptor: Sendable {
    func interceptAssistantChunk(_ event: AssistantChunkEvent) async throws -> String?
    func interceptAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> String?
}

public struct DefaultPolicyInterceptor: PolicyInterceptor {
    private let policy: ResponseContentPolicy?

    public init(policy: ResponseContentPolicy? = nil) {
        self.policy = policy
    }

    public func interceptAssistantChunk(_ event: AssistantChunkEvent) async throws -> String? {
        guard let policy else { return event.content }

        let outcome = try await policy.evaluateAssistantChunk(event)
        switch outcome {
        case .allow:
            return event.content
        case .deny:
            return nil
        case .redact(let pattern, let replacement):
            return event.content.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        case .confirm:
            return event.content
        }
    }

    public func interceptAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> String? {
        guard let policy else { return event.fullCompletion }

        let outcome = try await policy.evaluateAssistantCompletion(event)
        switch outcome {
        case .allow:
            return event.fullCompletion
        case .deny:
            return nil
        case .redact(let pattern, let replacement):
            return event.fullCompletion.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        case .confirm:
            return event.fullCompletion
        }
    }
}
