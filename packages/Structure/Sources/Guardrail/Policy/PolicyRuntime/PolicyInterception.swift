import Foundation

/// Result of applying a content `GuardrailDecision` (preserves deny reasons for UI).
public enum AssistantContentGuardrailOutput: Equatable, Sendable {
    case allowed(String)
    case denied(reason: String)
    /// Policy requires user approval before this content is accepted as final.
    case confirm(content: String, requiredFields: [String])
}
