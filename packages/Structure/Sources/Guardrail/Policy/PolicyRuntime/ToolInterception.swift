import Foundation

/// Errors thrown while applying a tool `GuardrailDecision`.
public enum ToolInvocationGuardrailError: Error, Equatable, Sendable {
    case denied(reason: String)
    case cancelled(reason: String)
}
