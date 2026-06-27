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
}

public enum PolicyDecision: Hashable, Sendable {
    case allow
    case deny(reason: String)
    case confirm(PolicyConfirmationRequest)
}

public protocol PolicyRule: Sendable {
    func evaluate(_ request: PolicyRequest) -> PolicyDecision?
}

public protocol PolicyConfirmationPresenting: Sendable {
    func confirm(_ request: PolicyConfirmationRequest) async -> Bool
}

public enum PolicyError: Error, Sendable, Equatable {
    case denied(String)
    case cancelled
}

public struct PolicyEngine: Sendable {
    public let rules: [any PolicyRule]

    public init(rules: [any PolicyRule]) {
        self.rules = rules
    }

    public func decision(for request: PolicyRequest) -> PolicyDecision {
        for rule in rules {
            if let decision = rule.evaluate(request) {
                return decision
            }
        }

        return .confirm(
            PolicyConfirmationRequest(
                title: "Confirm tool call",
                message: "This tool may change state or trigger side effects.",
                call: request.call,
                context: request.context
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

public struct PolicyToolCallInterceptor<Presenter: PolicyConfirmationPresenting>: ToolCallInterceptor {
    public let engine: PolicyEngine
    public let presenter: Presenter

    public init(engine: PolicyEngine, presenter: Presenter) {
        self.engine = engine
        self.presenter = presenter
    }

    public func intercept<R: Sendable>(
        _ request: PolicyRequest,
        proceed: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        switch engine.decision(for: request) {
        case .allow:
            return try await proceed()
        case .deny(let reason):
            throw PolicyError.denied(reason)
        case .confirm(let confirmation):
            if await presenter.confirm(confirmation) {
                return try await proceed()
            }
            throw PolicyError.cancelled
        }
    }
}
