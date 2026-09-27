import Foundation

/// Policy rule scopes. Interpreters load only their scope(s).
public enum GuardrailPolicyScope: String, Sendable, Hashable, CaseIterable {
    case toolInvocation = "tool_invocation"
    /// Legacy alias still accepted when loading tool rules.
    case toolCall = "tool_call"
    case workflowStart = "workflow_start"
    case assistantChunk = "assistant_chunk"
    case assistantCompletionContent = "assistant_completion_content"
    case assistantCompletion = "assistant_completion"

    public static var toolInvocationScopes: [GuardrailPolicyScope] { [.toolInvocation, .toolCall] }
    public static var assistantCompletionScopes: [GuardrailPolicyScope] {
        [.assistantCompletionContent, .assistantCompletion]
    }
}
