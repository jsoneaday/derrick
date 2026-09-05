import Foundation

public struct AllowToolNamesRule: ToolPolicyRule {
    public let toolNames: Set<String>

    public init<Names: Sequence>(toolNames: Names) where Names.Element == String {
        self.toolNames = Set(toolNames)
    }

    public func evaluate(_ request: PolicyRequest) -> PolicyDecision? {
        toolNames.contains(request.call.name) ? .allow : nil
    }
}

public struct DenyToolNamesRule: ToolPolicyRule {
    public let toolNames: Set<String>
    public let reason: String

    public init<Names: Sequence>(toolNames: Names, reason: String) where Names.Element == String {
        self.toolNames = Set(toolNames)
        self.reason = reason
    }

    public func evaluate(_ request: PolicyRequest) -> PolicyDecision? {
        toolNames.contains(request.call.name) ? .deny(reason: reason) : nil
    }
}

public struct ConfirmMutationRule: ToolPolicyRule {
    public init() {}

    public func evaluate(_ request: PolicyRequest) -> PolicyDecision? {
        guard request.call.effects.contains(.changesState) || request.call.effects.contains(.externalSideEffects) else {
            return nil
        }

        return .confirm(
            PolicyConfirmationRequest(
                title: "Confirm action",
                message: "This tool call can change state or trigger side effects. Confirm before proceeding.",
                call: request.call,
                context: request.context
            )
        )
    }
}
