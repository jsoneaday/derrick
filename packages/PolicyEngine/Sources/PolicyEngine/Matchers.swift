import Foundation

public protocol ToolCallMatcher: Sendable {
    func matches(_ call: ToolCall) -> Bool
}

public struct AnyToolCallMatcher: ToolCallMatcher {
    public let matchers: [any ToolCallMatcher]

    public init(_ matchers: [any ToolCallMatcher]) {
        self.matchers = matchers
    }

    public func matches(_ call: ToolCall) -> Bool {
        matchers.contains { $0.matches(call) }
    }
}

public struct AllToolCallMatcher: ToolCallMatcher {
    public let matchers: [any ToolCallMatcher]

    public init(_ matchers: [any ToolCallMatcher]) {
        self.matchers = matchers
    }

    public func matches(_ call: ToolCall) -> Bool {
        matchers.allSatisfy { $0.matches(call) }
    }
}

public struct NotToolCallMatcher: ToolCallMatcher {
    public let matcher: any ToolCallMatcher

    public init(_ matcher: any ToolCallMatcher) {
        self.matcher = matcher
    }

    public func matches(_ call: ToolCall) -> Bool {
        !matcher.matches(call)
    }
}

public struct ToolNameMatcher: ToolCallMatcher {
    public enum Kind: Sendable {
        case exact(String)
        case prefix(String)
        case contains(String)
        case anyOf(Set<String>)
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public func matches(_ call: ToolCall) -> Bool {
        switch kind {
        case .exact(let value):
            return call.name == value
        case .prefix(let value):
            return call.name.hasPrefix(value)
        case .contains(let value):
            return call.name.contains(value)
        case .anyOf(let values):
            return values.contains(call.name)
        }
    }
}

public struct ToolArgumentMatcher: ToolCallMatcher {
    public enum Kind: Sendable {
        case exists
        case exact(String)
        case prefix(String)
        case contains(String)
    }

    public let key: String
    public let kind: Kind

    public init(key: String, kind: Kind) {
        self.key = key
        self.kind = kind
    }

    public func matches(_ call: ToolCall) -> Bool {
        guard let value = call.arguments[key] else {
            return false
        }

        switch kind {
        case .exists:
            return true
        case .exact(let expected):
            return value == expected
        case .prefix(let expected):
            return value.hasPrefix(expected)
        case .contains(let expected):
            return value.contains(expected)
        }
    }
}

public struct ToolRiskMatcher: ToolCallMatcher {
    public let minimum: ToolCall.Risk

    public init(minimum: ToolCall.Risk) {
        self.minimum = minimum
    }

    public func matches(_ call: ToolCall) -> Bool {
        call.risk >= minimum
    }
}

public struct ToolEffectsMatcher: ToolCallMatcher {
    public let required: ToolCall.Effects

    public init(required: ToolCall.Effects) {
        self.required = required
    }

    public func matches(_ call: ToolCall) -> Bool {
        call.effects.contains(required)
    }
}

public struct ToolRule: PolicyRule {
    public enum Outcome: Sendable, Hashable {
        case allow
        case deny(reason: String)
        case confirm(title: String, message: String)
    }

    public let matcher: any ToolCallMatcher
    public let outcome: Outcome

    public init(matcher: any ToolCallMatcher, outcome: Outcome) {
        self.matcher = matcher
        self.outcome = outcome
    }

    public static func allow(_ matcher: any ToolCallMatcher) -> Self {
        Self(matcher: matcher, outcome: .allow)
    }

    public static func deny(_ matcher: any ToolCallMatcher, reason: String) -> Self {
        Self(matcher: matcher, outcome: .deny(reason: reason))
    }

    public static func confirm(
        _ matcher: any ToolCallMatcher,
        title: String = "Confirm action",
        message: String = "This tool call requires confirmation."
    ) -> Self {
        Self(matcher: matcher, outcome: .confirm(title: title, message: message))
    }

    public func evaluate(_ request: PolicyRequest) -> PolicyDecision? {
        guard matcher.matches(request.call) else {
            return nil
        }

        switch outcome {
        case .allow:
            return .allow
        case .deny(let reason):
            return .deny(reason: reason)
        case .confirm(let title, let message):
            return .confirm(.init(title: title, message: message, call: request.call, context: request.context))
        }
    }
}
