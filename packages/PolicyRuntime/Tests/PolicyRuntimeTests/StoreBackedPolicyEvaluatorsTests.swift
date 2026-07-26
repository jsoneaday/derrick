import XCTest
import MemorySystem
@testable import PolicyRuntime

final class StoreBackedPolicyEvaluatorsTests: XCTestCase {
    func test_toolPolicy_loadsRelevantScopeAndDeniesMatch() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "tool_invocation": [
                PolicyRule(
                    applicationName: "ui",
                    name: "deny-delete",
                    scope: "tool_invocation",
                    matcherJSON: #"{"tool_name":"delete_file"}"#,
                    outcomeJSON: #"{"action":"deny","reason":"blocked"}"#
                )
            ]
        ])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")
        let event = ToolInvocationEvent(
            sessionID: "s1",
            toolName: "delete_file",
            argumentsJSON: #"{"path":"/tmp/a"}"#
        )
        let outcome = try await policy.evaluateToolInvocation(event)
        XCTAssertEqual(outcome, .deny(reason: "blocked"))
    }

    func test_toolPolicy_skipsDisabledRuleEvenIfPresentInStore() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "tool_invocation": [
                PolicyRule(
                    applicationName: "ui",
                    name: "disabled-deny",
                    scope: "tool_invocation",
                    matcherJSON: #"{"tool_name":"python_script_exec"}"#,
                    outcomeJSON: #"{"action":"deny","reason":"should not run"}"#,
                    priority: 1000,
                    enabled: false
                ),
                PolicyRule(
                    applicationName: "ui",
                    name: "allow-python",
                    scope: "tool_invocation",
                    matcherJSON: #"{"tool_name":"python_script_exec"}"#,
                    outcomeJSON: #"{"action":"allow"}"#,
                    priority: 1,
                    enabled: true
                )
            ]
        ])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")
        let outcome = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "python_script_exec", argumentsJSON: "{}")
        )
        XCTAssertEqual(outcome, .allow)
    }

    func test_toolPolicy_deniesWhenNoRulesConfigured() async throws {
        let store = MockPolicyStore(rulesByScope: [:])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")
        let outcome = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "python_script_exec", argumentsJSON: "{}")
        )
        XCTAssertEqual(outcome, .deny(reason: StoreBackedToolGovernancePolicy.noRulesConfiguredReason))
    }

    func test_toolPolicy_deniesWhenNoRuleMatches() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "tool_invocation": [
                PolicyRule(
                    applicationName: "ui",
                    name: "deny-delete",
                    scope: "tool_invocation",
                    matcherJSON: #"{"tool_name":"delete_file"}"#,
                    outcomeJSON: #"{"action":"deny","reason":"blocked"}"#,
                    priority: 100
                )
            ]
        ])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")
        let outcome = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "python_script_exec", argumentsJSON: "{}")
        )
        XCTAssertEqual(outcome, .deny(reason: StoreBackedToolGovernancePolicy.noMatchingRuleReason))
    }

    func test_toolPolicy_prefersHigherPriorityAcrossScopes() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "tool_invocation": [
                PolicyRule(
                    applicationName: "ui",
                    name: "low-confirm",
                    scope: "tool_invocation",
                    matcherJSON: #"{"tool_name":"file_write"}"#,
                    outcomeJSON: #"{"action":"confirm","required_fields":["low"]}"#,
                    priority: 10
                )
            ],
            "tool_call": [
                PolicyRule(
                    applicationName: "ui",
                    name: "high-deny",
                    scope: "tool_call",
                    matcherJSON: #"{"tool_name":"file_write"}"#,
                    outcomeJSON: #"{"action":"deny","reason":"high priority"}"#,
                    priority: 100
                )
            ]
        ])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")
        let outcome = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "file_write", argumentsJSON: "{}")
        )
        XCTAssertEqual(outcome, .deny(reason: "high priority"))
    }

    func test_completionPolicy_matchesDetectedSensitivePatterns() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "assistant_completion_content": [
                PolicyRule(
                    applicationName: "ui",
                    name: "confirm-email",
                    scope: "assistant_completion_content",
                    matcherJSON: #"{"detected_patterns_any":["email"]}"#,
                    outcomeJSON: #"{"action":"confirm","required_fields":["review"]}"#
                )
            ]
        ])
        let policy = StoreBackedCompletionContentPolicy(store: store, applicationName: "ui")
        let outcome = try await policy.evaluateAssistantCompletion(
            AssistantCompletionEvent(
                sessionID: "s1",
                fullCompletion: "Please email me at hi@example.com",
                chunkCount: 1
            )
        )
        XCTAssertEqual(outcome, .confirm(requiredFields: ["review"]))
    }

    func test_completionPolicy_skipsDisabledRule() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "assistant_completion_content": [
                PolicyRule(
                    applicationName: "ui",
                    name: "disabled-confirm",
                    scope: "assistant_completion_content",
                    matcherJSON: #"{"detected_patterns_any":["email"]}"#,
                    outcomeJSON: #"{"action":"confirm","required_fields":["review"]}"#,
                    priority: 100,
                    enabled: false
                ),
                PolicyRule(
                    applicationName: "ui",
                    name: "allow-all",
                    scope: "assistant_completion_content",
                    matcherJSON: #"{}"#,
                    outcomeJSON: #"{"action":"allow"}"#,
                    priority: 1,
                    enabled: true
                )
            ]
        ])
        let policy = StoreBackedCompletionContentPolicy(store: store, applicationName: "ui")
        let outcome = try await policy.evaluateAssistantCompletion(
            AssistantCompletionEvent(
                sessionID: "s1",
                fullCompletion: "hi@example.com",
                chunkCount: 1
            )
        )
        XCTAssertEqual(outcome, .allow)
    }
}

private actor MockPolicyStore: PolicyStore {
    private let rulesByScope: [String: [PolicyRule]]

    init(rulesByScope: [String: [PolicyRule]]) {
        self.rulesByScope = rulesByScope
    }

    func loadRules(applicationName: String, scope: String) async throws -> [PolicyRule] {
        rulesByScope[scope] ?? []
    }

    func saveRule(_ rule: PolicyRule) async throws {}
    func saveApproval(_ approval: PolicyApproval) async throws {}
    func loadApprovals(sessionID: String, limit: Int) async throws -> [PolicyApproval] { [] }
    func logAuditEntry(_ entry: PolicyAuditLogEntry) async throws {}
    func auditLog(sessionID: String, limit: Int, page: Int) async throws -> [PolicyAuditLogEntry] { [] }
}
