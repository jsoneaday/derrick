import Foundation

/// Applies a `GuardrailDecision` for workflow starts.
public struct WorkflowStartGuardrailApplying: GuardrailApplying {
    public typealias Request = WorkflowStartRequest
    public typealias Output = Void

    private let hitl: any GuardrailHITLPresenting

    public init(hitl: any GuardrailHITLPresenting) {
        self.hitl = hitl
    }

    public func apply(_ decision: GuardrailDecision, for request: WorkflowStartRequest) async throws {
        switch decision {
        case .allow:
            return
        case .deny(let reason):
            throw WorkflowRuntimeError.deniedByGuardrail(reason)
        case .confirmHITL(let hitlRequest):
            let isJob: Bool = {
                if case .job = request.principal { return true }
                return false
            }()
            let presentation = GuardrailHITLPresentation(
                sessionID: request.sessionID,
                turnID: request.turnID ?? request.sessionID,
                subject: "workflow_start:\(request.kind.rawValue)",
                payloadJSON: request.inputJSON,
                hitl: hitlRequest,
                isJobContext: isJob
            )
            switch await hitl.resolve(presentation) {
            case .approved:
                return
            case .cancelled:
                let detail = hitlRequest.message ?? hitlRequest.title ?? "Workflow start was not approved."
                throw WorkflowRuntimeError.deniedByGuardrail(detail)
            }
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
