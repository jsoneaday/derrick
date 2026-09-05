import Testing
@testable import Structure

@Suite("Policy Engine")
struct PolicyEngineTests {
    @Test func deniesExplicitlyBlockedTools() {
        let engine = PolicyEngine(rules: [
            DenyToolNamesRule(toolNames: ["deleteFile"], reason: "Destructive operations are blocked.")
        ])

        let decision = engine.decision(for: .init(call: .init(name: "deleteFile"), context: .init(agentID: "a")))
        #expect({
            if case .deny(let reason) = decision {
                return reason.contains("blocked")
            }
            return false
        }())
    }

    @Test func confirmsMutatingCallsByDefault() {
        let engine = PolicyEngine(rules: [
            AllowToolNamesRule(toolNames: ["readFile"]),
            ConfirmMutationRule()
        ])

        let decision = engine.decision(for: .init(call: .init(name: "writeFile", effects: [.changesState]), context: .init(agentID: "a")))
        #expect({
            if case .confirm(let request) = decision {
                return request.title == "Confirm action"
            }
            return false
        }())
    }

    @Test func allowsExplicitlyAllowedTools() {
        let engine = PolicyEngine(rules: [
            AllowToolNamesRule(toolNames: ["readFile"]),
            ConfirmMutationRule()
        ])

        let decision = engine.decision(for: .init(call: .init(name: "readFile"), context: .init(agentID: "a")))
        #expect(decision == .allow)
    }

    @Test func matcherDslAllowsCompoundRules() {
        let engine = PolicyEngine(rules: [
            ToolRule.allow(AllToolCallMatcher([
                ToolNameMatcher(.prefix("read")),
                NotToolCallMatcher(ToolRiskMatcher(minimum: .high))
            ]))
        ])

        let decision = engine.decision(for: .init(call: .init(name: "readDocument", risk: .medium), context: .init(agentID: "a")))
        #expect(decision == .allow)
    }
}
