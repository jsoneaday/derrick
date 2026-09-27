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

    @Test func workflowStartApplyingAllowAndDeny() async throws {
        let applying = WorkflowStartGuardrailApplying(hitl: ImmediateGuardrailHITLPresenting(approved: true))
        let request = WorkflowStartRequest(
            kind: .pluginFactoryCreate,
            sessionID: "s",
            agentID: "ui",
            inputJSON: "{}",
            principal: .ui
        )
        try await applying.apply(.allow, for: request)
        do {
            try await applying.apply(.deny(reason: "blocked"), for: request)
            Issue.record("deny must throw")
        } catch let error as WorkflowRuntimeError {
            if case .deniedByGuardrail(let reason) = error {
                #expect(reason == "blocked")
            } else {
                Issue.record("Expected deniedByGuardrail")
            }
        }
    }

    @Test func workflowStartApplyingConfirmHITL() async throws {
        let request = WorkflowStartRequest(
            kind: .pluginFactoryCreate,
            sessionID: "s",
            agentID: "ui",
            inputJSON: "{}",
            principal: .ui
        )
        try await WorkflowStartGuardrailApplying(hitl: ImmediateGuardrailHITLPresenting(approved: true))
            .apply(.confirmHITL(GuardrailHITLRequest(requiredFields: ["ok"])), for: request)

        do {
            try await WorkflowStartGuardrailApplying(hitl: ImmediateGuardrailHITLPresenting(approved: false))
                .apply(.confirmHITL(GuardrailHITLRequest(title: "Need approval")), for: request)
            Issue.record("cancelled HITL must throw")
        } catch let error as WorkflowRuntimeError {
            if case .deniedByGuardrail = error {
                #expect(true)
            } else {
                Issue.record("Expected deniedByGuardrail")
            }
        }
    }

    @Test func toolInvocationApplyingAllowDenyRedact() async throws {
        let applying = ToolInvocationGuardrailApplying()
        let event = ToolInvocationEvent(
            sessionID: "s",
            toolName: "script_exec",
            argumentsJSON: #"{"code":"secret-token"}"#
        )
        let allowed = try await applying.apply(.allow, for: event)
        #expect(allowed.toolName == "script_exec")

        do {
            _ = try await applying.apply(.deny(reason: "nope"), for: event)
            Issue.record("deny must throw")
        } catch let error as ToolInvocationGuardrailError {
            if case .denied(let reason) = error {
                #expect(reason == "nope")
            } else {
                Issue.record("Expected denied")
            }
        }

        let redacted = try await applying.apply(
            .redactArgument(argumentKey: "code", pattern: "secret", replacement: "[REDACTED]"),
            for: event
        )
        #expect(redacted.argumentsJSON.contains("[REDACTED]"))
        #expect(!redacted.argumentsJSON.contains("secret-token"))
    }

    @Test func assistantContentApplyingChunkAndCompletion() {
        let applying = AssistantContentGuardrailApplying()
        let chunk = AssistantChunkEvent(sessionID: "s", chunkIndex: 0, content: "hello secret")
        let chunkOut = applying.apply(
            .redactContent(pattern: "secret", replacement: "[x]"),
            for: chunk
        )
        #expect(chunkOut == .allowed("hello [x]"))

        let completion = AssistantCompletionEvent(sessionID: "s", fullCompletion: "done", chunkCount: 1)
        let confirmOut = applying.apply(
            .confirmHITL(GuardrailHITLRequest(requiredFields: ["review"])),
            for: completion
        )
        #expect(confirmOut == .confirm(content: "done", requiredFields: ["review"]))
    }

    @Test func defaultWorkflowSeedsCoverCreateAndDenyEdit() {
        let rules = DefaultGuardrailPolicySeeds.workflowStartRules(applicationName: "ui")
        #expect(rules.contains { $0.name == "allow-workflow-plugin-factory-create" })
        #expect(rules.contains { $0.name == "deny-workflow-plugin-factory-edit" })
        #expect(rules.allSatisfy { $0.scope == "workflow_start" })
    }

    @Test func executionContextParseOptionalJSON() throws {
        let context = ExecutionContextWire(
            sessionID: "s",
            principal: .ui,
            capabilities: [.syncWebCrawl]
        )
        let json = try context.encodedJSON()
        let parsed = ExecutionContextWire.parseOptionalJSON(json)
        #expect(parsed?.capabilities.contains(.syncWebCrawl) == true)
        #expect(ExecutionContextWire.parseOptionalJSON(nil) == nil)
        #expect(ExecutionContextWire.parseOptionalJSON("  ") == nil)
    }
}
