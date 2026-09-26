import Foundation

/// Thin Guardrail adapter for workflow starts.
///
/// Policy owns the decision (`StoreBackedWorkflowAdmissionPolicy` / seeded `workflow_start` rules).
/// This type only applies that decision: allow, deny, or confirm HITL then continue/cancel.
public enum WorkflowAdmissionPolicy: Sendable {
    /// Apply a Policy decision for starting a workflow.
    ///
    /// - Parameters:
    ///   - decision: From the Policy engine.
    ///   - confirm: Invoked on `.confirmHITL`. Return `true` to proceed, `false` to cancel.
    public static func apply(
        _ decision: GuardrailDecision,
        confirm: () async -> Bool
    ) async throws {
        switch decision {
        case .allow:
            return
        case .deny(let reason):
            throw WorkflowRuntimeError.deniedByGuardrail(reason)
        case .confirmHITL(let hitl):
            let approved = await confirm()
            if approved {
                return
            }
            let detail = hitl.message ?? hitl.title ?? "Workflow start was not approved."
            throw WorkflowRuntimeError.deniedByGuardrail(detail)
        case .requireWorkflow:
            throw WorkflowRuntimeError.deniedByGuardrail(
                "requireWorkflow is not a valid decision for workflow start."
            )
        case .redactContent, .redactArgument:
            throw WorkflowRuntimeError.deniedByGuardrail(
                "Redaction is not a valid decision for workflow start."
            )
        }
    }
}
