import XCTest
@testable import MemorySystem

final class OnDemandPoliciesTests: XCTestCase {
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
        let policy = OnDemandToolGovernancePolicy(store: store, applicationName: "ui")
        let event = ToolInvocationEvent(
            sessionID: "s1",
            toolName: "delete_file",
            argumentsJSON: #"{"path":"/tmp/a"}"#
        )

        let outcome = try await policy.evaluateToolInvocation(event)
        XCTAssertEqual(outcome, .deny(reason: "blocked"))
    }

    func test_toolPolicy_fallsBackToToolCallScope() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "tool_call": [
                PolicyRule(
                    applicationName: "ui",
                    name: "confirm-write",
                    scope: "tool_call",
                    matcherJSON: #"{"tool_name_contains":"write"}"#,
                    outcomeJSON: #"{"action":"confirm","required_fields":["ticket"]}"#
                )
            ]
        ])
        let policy = OnDemandToolGovernancePolicy(store: store, applicationName: "ui")
        let event = ToolInvocationEvent(
            sessionID: "s1",
            toolName: "file_write",
            argumentsJSON: #"{"path":"/tmp/a"}"#
        )

        let outcome = try await policy.evaluateToolInvocation(event)
        XCTAssertEqual(outcome, .confirm(requiredFields: ["ticket"]))
    }

    func test_completionPolicy_redactsByLoadedRule() async throws {
        let store = MockPolicyStore(rulesByScope: [
            "assistant_chunk": [
                PolicyRule(
                    applicationName: "ui",
                    name: "redact-secret",
                    scope: "assistant_chunk",
                    matcherJSON: #"{"content_pattern":"secret"}"#,
                    outcomeJSON: #"{"action":"redact","pattern":"secret","replacement":"[REDACTED]"}"#
                )
            ]
        ])
        let policy = OnDemandCompletionContentPolicy(store: store, applicationName: "ui")
        let chunkEvent = AssistantChunkEvent(sessionID: "s1", chunkIndex: 0, content: "a secret value")

        let outcome = try await policy.evaluateAssistantChunk(chunkEvent)
        XCTAssertEqual(outcome, .redact(pattern: "secret", replacement: "[REDACTED]"))
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
        let policy = OnDemandCompletionContentPolicy(store: store, applicationName: "ui")
        let completionEvent = AssistantCompletionEvent(
            sessionID: "s1",
            fullCompletion: "Please email me at hi@example.com",
            chunkCount: 1
        )

        let outcome = try await policy.evaluateAssistantCompletion(completionEvent)
        XCTAssertEqual(outcome, .confirm(requiredFields: ["review"]))
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
