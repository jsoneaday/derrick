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

    // MARK: - Matcher combinators (item 2)

    func test_toolPolicy_all_combinator_requiresEveryChild() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "tool_invocation": [
                PolicyRule(
                    applicationName: "ui",
                    name: "all-python-with-code",
                    scope: "tool_invocation",
                    matcherJSON: #"{"all":[{"tool_name":"python_script_exec"},{"argument_key":"code","argument_exists":true}]}"#,
                    outcomeJSON: #"{"action":"confirm","required_fields":["review"]}"#
                ),
                PolicyRule(
                    applicationName: "ui",
                    name: "allow-rest",
                    scope: "tool_invocation",
                    matcherJSON: #"{}"#,
                    outcomeJSON: #"{"action":"allow"}"#,
                    priority: 0
                )
            ]
        ])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")

        let withCode = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(
                sessionID: "s1",
                toolName: "python_script_exec",
                argumentsJSON: #"{"code":"print(1)"}"#
            )
        )
        XCTAssertEqual(withCode, .confirm(requiredFields: ["review"]))

        let withoutCode = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(
                sessionID: "s1",
                toolName: "python_script_exec",
                argumentsJSON: #"{"script":"print(1)"}"#
            )
        )
        XCTAssertEqual(withoutCode, .allow)

        let otherTool = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(
                sessionID: "s1",
                toolName: "read_file",
                argumentsJSON: #"{"code":"x"}"#
            )
        )
        XCTAssertEqual(otherTool, .allow)
    }

    func test_toolPolicy_any_combinator_matchesOneChild() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "tool_invocation": [
                PolicyRule(
                    applicationName: "ui",
                    name: "any-write-tools",
                    scope: "tool_invocation",
                    matcherJSON: #"{"any":[{"tool_name":"file_write"},{"tool_name":"delete_file"}]}"#,
                    outcomeJSON: #"{"action":"deny","reason":"mutating tool"}"#
                ),
                PolicyRule(
                    applicationName: "ui",
                    name: "allow-rest",
                    scope: "tool_invocation",
                    matcherJSON: #"{}"#,
                    outcomeJSON: #"{"action":"allow"}"#,
                    priority: 0
                )
            ]
        ])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")

        let fileWrite = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "file_write", argumentsJSON: "{}")
        )
        XCTAssertEqual(fileWrite, .deny(reason: "mutating tool"))

        let deleteFile = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "delete_file", argumentsJSON: "{}")
        )
        XCTAssertEqual(deleteFile, .deny(reason: "mutating tool"))

        let readFile = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "read_file", argumentsJSON: "{}")
        )
        XCTAssertEqual(readFile, .allow)
    }

    func test_toolPolicy_not_combinator_invertsChild() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "tool_invocation": [
                PolicyRule(
                    applicationName: "ui",
                    name: "deny-non-session-memory",
                    scope: "tool_invocation",
                    matcherJSON: #"{"not":{"tool_name_prefix":"session_memory"}}"#,
                    outcomeJSON: #"{"action":"deny","reason":"only session memory allowed"}"#
                ),
                PolicyRule(
                    applicationName: "ui",
                    name: "allow-session",
                    scope: "tool_invocation",
                    matcherJSON: #"{"tool_name_prefix":"session_memory"}"#,
                    outcomeJSON: #"{"action":"allow"}"#,
                    priority: 0
                )
            ]
        ])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")

        let sessionTool = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "session_memory_search", argumentsJSON: "{}")
        )
        XCTAssertEqual(sessionTool, .allow)

        let otherTool = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "python_script_exec", argumentsJSON: "{}")
        )
        XCTAssertEqual(otherTool, .deny(reason: "only session memory allowed"))
    }

    func test_toolPolicy_nested_combinators() async throws {
        // (python OR shell) AND NOT (argument network_hosts exists)
        let matcher = """
        {"all":[
          {"any":[{"tool_name":"python_script_exec"},{"tool_name":"shell_exec"}]},
          {"not":{"argument_key":"network_hosts","argument_exists":true}}
        ]}
        """
        let store = MockPolicyStore(rulesByScope: [
            "tool_invocation": [
                PolicyRule(
                    applicationName: "ui",
                    name: "confirm-offline-scripts",
                    scope: "tool_invocation",
                    matcherJSON: matcher,
                    outcomeJSON: #"{"action":"confirm","required_fields":["offline_ok"]}"#
                ),
                PolicyRule(
                    applicationName: "ui",
                    name: "allow-rest",
                    scope: "tool_invocation",
                    matcherJSON: #"{}"#,
                    outcomeJSON: #"{"action":"allow"}"#,
                    priority: 0
                )
            ]
        ])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")

        let offlinePython = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(
                sessionID: "s1",
                toolName: "python_script_exec",
                argumentsJSON: #"{"code":"x"}"#
            )
        )
        XCTAssertEqual(offlinePython, .confirm(requiredFields: ["offline_ok"]))

        let networkedPython = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(
                sessionID: "s1",
                toolName: "python_script_exec",
                argumentsJSON: #"{"code":"x","network_hosts":["a.com"]}"#
            )
        )
        XCTAssertEqual(networkedPython, .allow)

        let otherTool = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "read_file", argumentsJSON: "{}")
        )
        XCTAssertEqual(otherTool, .allow)
    }

    func test_toolPolicy_tool_name_prefix_leaf() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "tool_invocation": [
                PolicyRule(
                    applicationName: "ui",
                    name: "confirm-session-tools",
                    scope: "tool_invocation",
                    matcherJSON: #"{"tool_name_prefix":"session_"}"#,
                    outcomeJSON: #"{"action":"confirm","required_fields":["ok"]}"#
                ),
                PolicyRule(
                    applicationName: "ui",
                    name: "allow-rest",
                    scope: "tool_invocation",
                    matcherJSON: #"{}"#,
                    outcomeJSON: #"{"action":"allow"}"#,
                    priority: 0
                )
            ]
        ])
        let policy = StoreBackedToolGovernancePolicy(store: store, applicationName: "ui")
        let sessionTool = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "session_memory_search", argumentsJSON: "{}")
        )
        XCTAssertEqual(sessionTool, .confirm(requiredFields: ["ok"]))

        let otherTool = try await policy.evaluateToolInvocation(
            ToolInvocationEvent(sessionID: "s1", toolName: "python_script_exec", argumentsJSON: "{}")
        )
        XCTAssertEqual(otherTool, .allow)
    }

    func test_completionPolicy_any_combinator_for_sensitive_patterns() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "assistant_completion_content": [
                PolicyRule(
                    applicationName: "ui",
                    name: "confirm-sensitive",
                    scope: "assistant_completion_content",
                    matcherJSON: #"{"any":[{"detected_patterns_any":["email"]},{"detected_patterns_any":["ssn"]}]}"#,
                    outcomeJSON: #"{"action":"confirm","required_fields":["review"]}"#
                ),
                PolicyRule(
                    applicationName: "ui",
                    name: "allow-rest",
                    scope: "assistant_completion_content",
                    matcherJSON: #"{}"#,
                    outcomeJSON: #"{"action":"allow"}"#,
                    priority: 0
                )
            ]
        ])
        let policy = StoreBackedCompletionContentPolicy(store: store, applicationName: "ui")
        let ssn = try await policy.evaluateAssistantCompletion(
            AssistantCompletionEvent(
                sessionID: "s1",
                fullCompletion: "SSN 123-45-6789",
                chunkCount: 1
            )
        )
        XCTAssertEqual(ssn, .confirm(requiredFields: ["review"]))

        let plain = try await policy.evaluateAssistantCompletion(
            AssistantCompletionEvent(
                sessionID: "s1",
                fullCompletion: "hello world",
                chunkCount: 1
            )
        )
        XCTAssertEqual(plain, .allow)
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
