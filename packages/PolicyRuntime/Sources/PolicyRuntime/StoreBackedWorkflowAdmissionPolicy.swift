import Foundation
import Structure

/// Store-backed workflow start admission. Scope: `workflow_start`.
public struct StoreBackedWorkflowAdmissionPolicy: Sendable {
    private let store: any PolicyStore
    private let applicationName: String

    public init(store: any PolicyStore, applicationName: String) {
        self.store = store
        self.applicationName = applicationName
    }

    public func evaluate(_ request: WorkflowStartRequest) async throws -> GuardrailDecision {
        let rules = try await loadRules()
        guard !rules.isEmpty else {
            return .deny(reason: Self.noRulesConfiguredReason)
        }

        for rule in rules {
            guard rule.enabled else { continue }
            guard let matcher = try? decode(WorkflowMatcher.self, from: rule.matcherJSON) else {
                continue
            }
            guard matcher.matches(kind: request.kind) else {
                continue
            }
            guard let outcome = try? decode(WorkflowOutcomeRule.self, from: rule.outcomeJSON) else {
                continue
            }
            return outcome.decision
        }

        return .deny(reason: Self.noMatchingRuleReason)
    }

    public static let noRulesConfiguredReason =
        "No workflow_start rules are configured; denying by default."

    public static let noMatchingRuleReason =
        "No workflow_start rule matched this kind; denying by default."

    private func loadRules() async throws -> [PolicyRule] {
        try await store.loadRules(applicationName: applicationName, scope: "workflow_start")
            .filter(\.enabled)
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid UTF-8 in policy JSON.")
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct WorkflowMatcher: Decodable {
    let workflowKind: String?
    let workflowKindAny: [String]?

    enum CodingKeys: String, CodingKey {
        case workflowKind = "workflow_kind"
        case workflowKindAny = "workflow_kind_any"
    }

    func matches(kind: WorkflowKind) -> Bool {
        if let workflowKind, kind.rawValue != workflowKind {
            return false
        }
        if let workflowKindAny {
            guard workflowKindAny.contains(kind.rawValue) else { return false }
        }
        return true
    }
}

private struct WorkflowOutcomeRule: Decodable {
    let action: String
    let reason: String?
    let requiredFields: [String]?
    let title: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case action
        case reason
        case requiredFields = "required_fields"
        case title
        case message
    }

    var decision: GuardrailDecision {
        switch action.lowercased() {
        case "allow":
            return .allow
        case "deny":
            return .deny(reason: reason ?? "Workflow start denied by policy.")
        case "confirm":
            return .confirmHITL(
                GuardrailHITLRequest(
                    requiredFields: requiredFields ?? ["user_approval"],
                    title: title,
                    message: message
                )
            )
        case "require_workflow":
            // Already starting a workflow; treat as deny.
            return .deny(reason: reason ?? "require_workflow is not valid for workflow_start.")
        default:
            return .deny(reason: "Unknown workflow_start action '\(action)'; denying by default.")
        }
    }
}
