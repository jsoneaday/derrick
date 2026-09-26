import Testing
@testable import Structure

@Suite("Guardrail")
struct GuardrailDecisionTests {
    @Test func effectorAdmissionUsesGuardrailDecision() {
        let denied = EffectorAdmissionPolicy.syncWebCrawlDecision(
            context: nil,
            principal: .ui
        )
        #expect(!denied.isAllow)
        if case .deny = denied {
            #expect(true)
        } else {
            Issue.record("Expected deny for UI without crawl capability")
        }

        let allowed = EffectorAdmissionPolicy.syncWebCrawlDecision(
            context: nil,
            principal: .job(jobID: "job-1")
        )
        #expect(allowed == .allow)
    }

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

    @Test func workflowAdmissionAllowsCreateAndDeniesEditPlaceholder() throws {
        #expect(WorkflowAdmissionPolicy.decision(kind: .pluginFactoryCreate) == .allow)
        #expect(WorkflowAdmissionPolicy.decision(kind: .connectorAuthDiscover) == .allow)

        let edit = WorkflowAdmissionPolicy.decision(kind: .pluginFactoryEdit)
        #expect(!edit.isAllow)

        let request = WorkflowStartRequest(
            kind: .pluginFactoryEdit,
            sessionID: "s",
            agentID: "ui",
            inputJSON: "{}",
            principal: .ui
        )
        do {
            try WorkflowAdmissionPolicy.admitOrThrow(request)
            Issue.record("edit placeholder must be denied")
        } catch let error as WorkflowRuntimeError {
            if case .deniedByGuardrail = error {
                #expect(true)
            } else {
                Issue.record("Expected deniedByGuardrail, got \(error)")
            }
        }
    }
}
