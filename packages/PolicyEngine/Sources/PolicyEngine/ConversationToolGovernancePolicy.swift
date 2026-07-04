import Foundation
import MemorySystem
import PolicyEngine

public class ConversationToolGovernancePolicy: ToolGovernancePolicy {
    private let policyEngine: PolicyEngine
    private let applicationName: String

    public init(policyEngine: PolicyEngine, applicationName: String) {
        self.policyEngine = policyEngine
        self.applicationName = applicationName
    }

    public func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
        let request = PolicyRequest(
            scope: "tool_invocation",
            matcher: ToolInvocationMatcher(
                toolName: event.toolName,
                argumentsLength: event.argumentsJSON.count
            ),
            actor: "assistant"
        )

        let decision = try await policyEngine.decision(for: request)

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

private struct ToolInvocationMatcher: Codable, Sendable {
    let toolName: String
    let argumentsLength: Int
}
