import Foundation

/// Applies a `GuardrailDecision` for assistant chunk / completion content.
public struct AssistantContentGuardrailApplying: Sendable {
    public init() {}

    /// Streaming chunks: never modal mid-token. Confirm is deferred to completion.
    public func apply(
        _ decision: GuardrailDecision,
        for chunk: AssistantChunkEvent
    ) -> AssistantContentGuardrailOutput {
        switch decision {
        case .allow:
            return .allowed(chunk.content)
        case .deny(let reason):
            return .denied(reason: reason)
        case .redactContent(let pattern, let replacement):
            let redacted = chunk.content.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
            return .allowed(redacted)
        case .confirmHITL, .requireWorkflow, .redactArgument:
            return .allowed(chunk.content)
        }
    }

    public func apply(
        _ decision: GuardrailDecision,
        for completion: AssistantCompletionEvent
    ) -> AssistantContentGuardrailOutput {
        switch decision {
        case .allow:
            return .allowed(completion.fullCompletion)
        case .deny(let reason):
            return .denied(reason: reason)
        case .redactContent(let pattern, let replacement):
            let redacted = completion.fullCompletion.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
            return .allowed(redacted)
        case .confirmHITL(let hitl):
            return .confirm(content: completion.fullCompletion, requiredFields: hitl.requiredFields)
        case .requireWorkflow, .redactArgument:
            return .denied(reason: "Content policy returned an unsupported control decision.")
        }
    }
}
