import Foundation

/// Baseline Guardrail Policy rules Derrick seeds on first launch.
public enum DefaultGuardrailPolicySeeds: Sendable {
    /// `workflow_start` rules: allow Derrick-owned kinds; deny edit placeholder and `none`.
    public static func workflowStartRules(applicationName: String) -> [PolicyRule] {
        [
            PolicyRule(
                applicationName: applicationName,
                name: "allow-workflow-plugin-factory-create",
                scope: "workflow_start",
                matcherJSON: #"{"workflow_kind":"plugin_factory_create"}"#,
                outcomeJSON: #"{"action":"allow"}"#,
                priority: 100
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "allow-workflow-connector-auth-discover",
                scope: "workflow_start",
                matcherJSON: #"{"workflow_kind":"connector_auth_discover"}"#,
                outcomeJSON: #"{"action":"allow"}"#,
                priority: 100
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "allow-workflow-job-step",
                scope: "workflow_start",
                matcherJSON: #"{"workflow_kind":"job_step"}"#,
                outcomeJSON: #"{"action":"allow"}"#,
                priority: 100
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "allow-workflow-interactive-tool",
                scope: "workflow_start",
                matcherJSON: #"{"workflow_kind":"interactive_tool"}"#,
                outcomeJSON: #"{"action":"allow"}"#,
                priority: 100
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "deny-workflow-plugin-factory-edit",
                scope: "workflow_start",
                matcherJSON: #"{"workflow_kind":"plugin_factory_edit"}"#,
                outcomeJSON: #"{"action":"deny","reason":"Plugin edit workflow is reserved and not enabled yet."}"#,
                priority: 1000
            ),
            PolicyRule(
                applicationName: applicationName,
                name: "deny-workflow-none",
                scope: "workflow_start",
                matcherJSON: #"{"workflow_kind":"none"}"#,
                outcomeJSON: #"{"action":"deny","reason":"A workflow kind is required."}"#,
                priority: 1000
            ),
        ]
    }

    /// Idempotently insert `workflow_start` rules into a Policy store.
    public static func seedWorkflowStartRulesIfNeeded(
        store: any PolicyStore,
        applicationName: String
    ) async throws {
        for rule in workflowStartRules(applicationName: applicationName) {
            let existing = try await store.loadRules(applicationName: applicationName, scope: rule.scope)
            guard existing.contains(where: { $0.name == rule.name }) == false else {
                continue
            }
            try await store.saveRule(rule)
        }
    }
}
