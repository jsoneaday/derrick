import Foundation

public enum ToolInterceptionDecision: Equatable, Sendable {
    case allow(ToolInvocationEvent)
    case deny(reason: String)
    case confirm(ToolInvocationEvent, requiredFields: [String])
}

/// Errors thrown by confirm-before-proceed tool interception.
public enum ToolInvocationInterceptionError: Error, Equatable, Sendable {
    case denied(reason: String)
    case cancelled(reason: String)
}

/// Result of asking the user to approve a tool that policy marked as `confirmHITL`.
public enum ToolInvocationConfirmation: Equatable, Sendable {
    /// Proceed with this (possibly edited) invocation event.
    case approved(ToolInvocationEvent)
    /// User (or system) cancelled confirmation.
    case cancelled(actor: String?)
}

/// Tool Policy evaluator. Returns the canonical `GuardrailDecision`.
public protocol ToolGovernancePolicy: Sendable {
    func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> GuardrailDecision
}

public protocol ToolRequestInterceptor: Sendable {
    func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolInterceptionDecision
    func interceptToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolInvocationEvent?

    /// Evaluate policy, optionally confirm with the user, then run `proceed` with the gated event.
    ///
    /// Control flow:
    /// - allow / redact → `proceed(processedEvent)`
    /// - deny → throws `ToolInvocationInterceptionError.denied`
    /// - confirmHITL → `confirm(...)`; on approve → `proceed`; on cancel → throws `.cancelled`
    func interceptAndRun<R: Sendable>(
        _ event: ToolInvocationEvent,
        confirm: nonisolated(nonsending) @escaping @Sendable (ToolInvocationEvent, [String]) async throws -> ToolInvocationConfirmation,
        proceed: nonisolated(nonsending) @escaping @Sendable (ToolInvocationEvent) async throws -> R
    ) async throws -> R
}

/// Historical alias — prefer `GuardrailDecision`.
@available(*, deprecated, renamed: "GuardrailDecision")
public typealias ToolGovernanceOutcome = GuardrailDecision
