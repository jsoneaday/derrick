import Foundation
import MemorySystem

public final class ConversationToolGovernancePolicy: ToolGovernancePolicy {
    private let policyEngine: PolicyEngine
    private let applicationName: String

    public init(policyEngine: PolicyEngine, applicationName: String) {
        self.policyEngine = policyEngine
        self.applicationName = applicationName
    }

    public func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
        let request = PolicyRequest(
            call: ToolCall(
                name: event.toolName,
                arguments: ["argumentsLength": String(event.argumentsJSON.count)],
                effects: .externalSideEffects,
                risk: .medium
            ),
            context: PolicyContext(agentID: applicationName, caller: "assistant")
        )

        let decision = policyEngine.decision(for: request)

        switch decision {
        case .allow:
            return .allow
        case .deny:
            return .deny(reason: "Policy engine denied tool invocation: \(event.toolName)")
        case .confirm:
            return .confirm(requiredFields: ["user_approval"])
        }
    }
}
