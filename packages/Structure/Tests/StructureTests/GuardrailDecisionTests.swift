import Testing
@testable import Structure

@Suite("Guardrail")
struct GuardrailDecisionTests {
    @Test func policyEngineSharesGuardrailVocabulary() {
        let engine = PolicyEngine(rules: [
            DenyToolNamesRule(toolNames: ["x"], reason: "no")
        ])
        let decision = engine.decision(for: .init(call: .init(name: "x"), context: .init(agentID: "a")))
        #expect({
            if case .deny = decision { return true }
            return false
        }())
    }

    @Test func pluginFactoryEditKindRemainsPlaceholder() {
        #expect(WorkflowKind.pluginFactoryEdit.rawValue == "plugin_factory_edit")
        #expect(WorkflowKind.allCases.contains(.pluginFactoryEdit))
    }

    @Test func workflowAdmissionApplyAllowAndDeny() async throws {
        try await WorkflowAdmissionPolicy.apply(.allow) { true }
        do {
            try await WorkflowAdmissionPolicy.apply(.deny(reason: "blocked")) { true }
            Issue.record("deny must throw")
        } catch let error as WorkflowRuntimeError {
            if case .deniedByGuardrail(let reason) = error {
                #expect(reason == "blocked")
            } else {
                Issue.record("Expected deniedByGuardrail")
            }
        }
    }

    @Test func workflowAdmissionApplyConfirmHITL() async throws {
        try await WorkflowAdmissionPolicy.apply(
            .confirmHITL(GuardrailHITLRequest(requiredFields: ["ok"]))
        ) { true }

        do {
            try await WorkflowAdmissionPolicy.apply(
                .confirmHITL(GuardrailHITLRequest(title: "Need approval"))
            ) { false }
            Issue.record("cancelled HITL must throw")
        } catch let error as WorkflowRuntimeError {
            if case .deniedByGuardrail = error {
                #expect(true)
            } else {
                Issue.record("Expected deniedByGuardrail")
            }
        }
    }

    @Test func defaultWorkflowSeedsCoverCreateAndDenyEdit() {
        let rules = DefaultGuardrailPolicySeeds.workflowStartRules(applicationName: "ui")
        #expect(rules.contains { $0.name == "allow-workflow-plugin-factory-create" })
        #expect(rules.contains { $0.name == "deny-workflow-plugin-factory-edit" })
        #expect(rules.allSatisfy { $0.scope == "workflow_start" })
    }
}
