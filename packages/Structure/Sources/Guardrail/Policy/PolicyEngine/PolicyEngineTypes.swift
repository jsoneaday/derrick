import Foundation

public struct PolicyContext: Hashable, Sendable {
    public let agentID: String
    public let sessionID: String?
    public let caller: String?

    public init(agentID: String, sessionID: String? = nil, caller: String? = nil) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.caller = caller
    }
}

public struct ToolCall: Hashable, Sendable {
    public enum Risk: Int, Codable, Sendable, Comparable {
        case low = 0
        case medium = 1
        case high = 2
        case destructive = 3

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public struct Effects: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let readsState = Self(rawValue: 1 << 0)
        public static let changesState = Self(rawValue: 1 << 1)
        public static let externalSideEffects = Self(rawValue: 1 << 2)
    }

    public let name: String
    public let arguments: [String: String]
    public let effects: Effects
    public let risk: Risk

    public init(name: String, arguments: [String: String] = [:], effects: Effects = .readsState, risk: Risk = .low) {
        self.name = name
        self.arguments = arguments
        self.effects = effects
        self.risk = risk
    }
}

public struct PolicyRequest: Hashable, Sendable {
    public let call: ToolCall
    public let context: PolicyContext

    public init(call: ToolCall, context: PolicyContext) {
        self.call = call
        self.context = context
    }
}

public struct PolicyConfirmationRequest: Hashable, Sendable {
    public let title: String
    public let message: String
    public let call: ToolCall
    public let context: PolicyContext

    public init(title: String, message: String, call: ToolCall, context: PolicyContext) {
        self.title = title
        self.message = message
        self.call = call
        self.context = context
    }

    public var guardrailHITL: GuardrailHITLRequest {
        GuardrailHITLRequest(
            requiredFields: ["user_approval"],
            title: title,
            message: message
        )
    }
}

/// In-memory tool rules used by `PolicyEngine`. Prefer store-backed `PolicyRule` for production.
public protocol ToolPolicyRule: Sendable {
    func evaluate(_ request: PolicyRequest) -> GuardrailDecision?
}

public protocol PolicyConfirmationPresenting: Sendable {
    func confirm(_ request: PolicyConfirmationRequest) async -> Bool
}

public enum PolicyError: Error, Sendable, Equatable {
    case denied(String)
    case cancelled
}

/// In-memory rule list that produces `GuardrailDecision`. Production chat uses store-backed evaluators;
/// this engine shares the same decision vocabulary.
public struct PolicyEngine: Sendable {
    public let rules: [any ToolPolicyRule]

    public init(rules: [any ToolPolicyRule]) {
        self.rules = rules
    }

    public func decision(for request: PolicyRequest) -> GuardrailDecision {
        for rule in rules {
            if let decision = rule.evaluate(request) {
                return decision
            }
        }

        return .confirmHITL(
            GuardrailHITLRequest(
                requiredFields: ["user_approval"],
                title: "Confirm tool call",
                message: "This tool may change state or trigger side effects."
            )
        )
    }
}

public protocol ToolCallInterceptor: Sendable {
    func intercept<R: Sendable>(
        _ request: PolicyRequest,
        proceed: @escaping @Sendable () async throws -> R
    ) async throws -> R
}
