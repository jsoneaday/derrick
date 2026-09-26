import XCTest
import Structure
@testable import PolicyRuntime

final class StoreBackedWorkflowAdmissionPolicyTests: XCTestCase {
    func test_allowsSeededCreateAndDeniesEdit() async throws {
        let store = MockWorkflowPolicyStore()
        for rule in DefaultGuardrailPolicySeeds.workflowStartRules(applicationName: "ui") {
            try await store.saveRule(rule)
        }
        let policy = StoreBackedWorkflowAdmissionPolicy(store: store, applicationName: "ui")

        let create = try await policy.evaluate(
            WorkflowStartRequest(
                kind: .pluginFactoryCreate,
                sessionID: "s",
                agentID: "ui",
                inputJSON: "{}",
                principal: .ui
            )
        )
        XCTAssertEqual(create, .allow)

        let edit = try await policy.evaluate(
            WorkflowStartRequest(
                kind: .pluginFactoryEdit,
                sessionID: "s",
                agentID: "ui",
                inputJSON: "{}",
                principal: .ui
            )
        )
        guard case .deny = edit else {
            return XCTFail("edit placeholder must be denied by Policy rule")
        }
    }

    func test_confirmOutcomeReturnsHITL() async throws {
        let store = MockWorkflowPolicyStore(rulesByScope: [
            "workflow_start": [
                PolicyRule(
                    applicationName: "ui",
                    name: "confirm-create",
                    scope: "workflow_start",
                    matcherJSON: #"{"workflow_kind":"plugin_factory_create"}"#,
                    outcomeJSON: #"{"action":"confirm","required_fields":["review"],"title":"Approve create"}"#
                )
            ]
        ])
        let policy = StoreBackedWorkflowAdmissionPolicy(store: store, applicationName: "ui")
        let decision = try await policy.evaluate(
            WorkflowStartRequest(
                kind: .pluginFactoryCreate,
                sessionID: "s",
                agentID: "ui",
                inputJSON: "{}",
                principal: .ui
            )
        )
        guard case .confirmHITL(let hitl) = decision else {
            return XCTFail("expected confirmHITL")
        }
        XCTAssertEqual(hitl.requiredFields, ["review"])
        XCTAssertEqual(hitl.title, "Approve create")
    }
}

private final class MockWorkflowPolicyStore: PolicyStore, @unchecked Sendable {
    private var rulesByScope: [String: [PolicyRule]]

    init(rulesByScope: [String: [PolicyRule]] = [:]) {
        self.rulesByScope = rulesByScope
    }

    func loadRules(applicationName: String, scope: String) async throws -> [PolicyRule] {
        rulesByScope[scope] ?? []
    }

    func saveRule(_ rule: PolicyRule) async throws {
        var rules = rulesByScope[rule.scope] ?? []
        rules.removeAll { $0.name == rule.name }
        rules.append(rule)
        rulesByScope[rule.scope] = rules
    }

    func saveApproval(_ approval: PolicyApproval) async throws {}
    func loadApprovals(sessionID: String, limit: Int) async throws -> [PolicyApproval] { [] }
    func logAuditEntry(_ entry: PolicyAuditLogEntry) async throws {}
    func auditLog(sessionID: String, limit: Int, page: Int) async throws -> [PolicyAuditLogEntry] { [] }
}
