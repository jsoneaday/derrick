import Testing
@testable import PolicyEngine

@Suite("Policy Engine")
struct PolicyEngineTests {
    private struct AlwaysConfirmPresenter: PolicyConfirmationPresenting {
        let shouldConfirm: Bool

        func confirm(_ request: PolicyConfirmationRequest) async -> Bool {
            shouldConfirm
        }
    }

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

    @Test func interceptorRunsProceedOnlyAfterConfirmation() async throws {
        let engine = PolicyEngine(rules: [
            ToolRule.confirm(ToolNameMatcher(.exact("writeFile")))
        ])
        let interceptor = PolicyToolCallInterceptor(interceptor: engine, presenter: AlwaysConfirmPresenter(shouldConfirm: true))
        let adapter = PolicyToolCallInterceptorAdapter(interceptor: interceptor)

        let result: String = try await adapter.intercept(
            .init(
                request: .init(call: .init(name: "writeFile", effects: [.changesState]), context: .init(agentID: "a")),
                payload: "payload",
                proceed: { value in value.uppercased() }
            )
        )

        #expect(result == "PAYLOAD")
    }

    @Test func interceptorRejectsWhenConfirmationIsDenied() async throws {
        let engine = PolicyEngine(rules: [
            ToolRule.confirm(ToolNameMatcher(.exact("writeFile")))
        ])
        let interceptor = PolicyToolCallInterceptor(interceptor: engine, presenter: AlwaysConfirmPresenter(shouldConfirm: false))

        do {
            _ = try await interceptor.intercept(
                .init(call: .init(name: "writeFile", effects: [.changesState]), context: .init(agentID: "a"))
            ) {
                "ok"
            }
            Issue.record("Expected cancellation error.")
        } catch PolicyError.cancelled {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
