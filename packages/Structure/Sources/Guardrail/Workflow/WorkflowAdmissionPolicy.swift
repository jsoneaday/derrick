import Foundation

/// Guardrail admission for starting a workflow. Callers propose; Policy decides.
///
/// Derrick-owned kinds are allowed. `pluginFactoryEdit` stays denied until editability ships.
public enum WorkflowAdmissionPolicy: Sendable {
    public static func decision(for request: WorkflowStartRequest) -> GuardrailDecision {
        decision(kind: request.kind)
    }

    public static func decision(kind: WorkflowKind) -> GuardrailDecision {
        switch kind {
        case .pluginFactoryCreate, .connectorAuthDiscover, .jobStep, .interactiveTool:
            return .allow
        case .pluginFactoryEdit:
            return .deny(
                reason: "Plugin edit workflow is reserved and not enabled yet."
            )
        case .none:
            return .deny(reason: "A workflow kind is required.")
        }
    }

    /// Throws `WorkflowRuntimeError.deniedByGuardrail` unless the decision is `.allow`.
    public static func admitOrThrow(_ request: WorkflowStartRequest) throws {
        switch decision(for: request) {
        case .allow:
            return
        case .deny(let reason):
            throw WorkflowRuntimeError.deniedByGuardrail(reason)
        case .confirmHITL(let hitl):
            let detail = hitl.message ?? hitl.title ?? "Workflow start requires confirmation."
            throw WorkflowRuntimeError.deniedByGuardrail(detail)
        case .requireWorkflow, .redactContent, .redactArgument:
            throw WorkflowRuntimeError.deniedByGuardrail(
                "Workflow start returned an unsupported Guardrail decision."
            )
        }
    }
}
