import Foundation
import MemorySystem
import Structure

/// Store-backed tool governance: loads rules from `PolicyStore`, matches, returns first enabled hit.
public struct StoreBackedToolGovernancePolicy: ToolGovernancePolicy {
    private let store: any PolicyStore
    private let applicationName: String

    public init(store: any PolicyStore, applicationName: String) {
        self.store = store
        self.applicationName = applicationName
    }

    public func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
        let rules = try await loadRules(scopes: ["tool_invocation", "tool_call"])
        guard !rules.isEmpty else {
            return .deny(reason: Self.noRulesConfiguredReason)
        }

        let argumentsObject = parseJSONObject(from: event.argumentsJSON)
        for rule in rules {
            guard rule.enabled else { continue }
            guard let matcher = try? decode(ToolMatcher.self, from: rule.matcherJSON) else {
                continue
            }
            guard matcher.matches(event: event, arguments: argumentsObject) else {
                continue
            }
            guard let outcome = try? decode(OutcomeRule.self, from: rule.outcomeJSON) else {
                continue
            }
            return outcome.toolOutcome
        }

        return .deny(reason: Self.noMatchingRuleReason)
    }

    public static let noRulesConfiguredReason =
        "No tool governance rules are configured; denying by default."

    public static let noMatchingRuleReason =
        "No tool governance rule matched this request; denying by default."

    private func loadRules(scopes: [String]) async throws -> [PolicyRule] {
        var loaded: [PolicyRule] = []
        for scope in scopes {
            loaded.append(contentsOf: try await store.loadRules(applicationName: applicationName, scope: scope))
        }
        return loaded
            .filter(\.enabled)
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.createdAt > rhs.createdAt
            }
    }
}

/// Store-backed assistant content policy for chunks and full completions.
public struct StoreBackedCompletionContentPolicy: PolicyEvaluator {
    private let store: any PolicyStore
    private let applicationName: String

    public init(store: any PolicyStore, applicationName: String) {
        self.store = store
        self.applicationName = applicationName
    }

    public func evaluateAssistantChunk(_ event: AssistantChunkEvent) async throws -> PolicyDecisionOutcome {
        let rules = try await loadRules(scopes: ["assistant_chunk"])
        guard !rules.isEmpty else {
            return .deny(reason: Self.noRulesConfiguredReason)
        }

        for rule in rules {
            guard rule.enabled else { continue }
            guard let matcher = try? decode(ContentMatcher.self, from: rule.matcherJSON) else {
                continue
            }
            guard matcher.matches(content: event.content) else {
                continue
            }
            guard let outcome = try? decode(OutcomeRule.self, from: rule.outcomeJSON) else {
                continue
            }
            return outcome.contentOutcome(fallbackPattern: matcher.contentPattern)
        }

        return .deny(reason: Self.noMatchingRuleReason)
    }

    public func evaluateAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> PolicyDecisionOutcome {
        let rules = try await loadRules(scopes: ["assistant_completion_content", "assistant_completion"])
        guard !rules.isEmpty else {
            return .deny(reason: Self.noRulesConfiguredReason)
        }

        let detectedPatterns = detectSensitivePatterns(in: event.fullCompletion)
        for rule in rules {
            guard rule.enabled else { continue }
            guard let matcher = try? decode(CompletionMatcher.self, from: rule.matcherJSON) else {
                continue
            }
            guard matcher.matches(content: event.fullCompletion, detectedPatterns: detectedPatterns) else {
                continue
            }
            guard let outcome = try? decode(OutcomeRule.self, from: rule.outcomeJSON) else {
                continue
            }
            return outcome.contentOutcome(fallbackPattern: matcher.contentPattern)
        }

        return .deny(reason: Self.noMatchingRuleReason)
    }

    public static let noRulesConfiguredReason =
        "No content governance rules are configured; denying by default."

    public static let noMatchingRuleReason =
        "No content governance rule matched this content; denying by default."

    private func loadRules(scopes: [String]) async throws -> [PolicyRule] {
        var loaded: [PolicyRule] = []
        for scope in scopes {
            loaded.append(contentsOf: try await store.loadRules(applicationName: applicationName, scope: scope))
        }
        return loaded
            .filter(\.enabled)
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.createdAt > rhs.createdAt
            }
    }
}

// MARK: - Matchers / outcomes

/// Recursive JSON matcher for tool invocations.
///
/// Leaf fields (AND together when present):
/// - `tool_name`, `tool_name_contains`, `tool_name_prefix`
/// - `min_arguments_length`, `argument_key`, `argument_pattern`, `argument_exists`
///
/// Combinators (exactly one wins when present; checked in order `all`, `any`, `not`):
/// - `{"all":[...matchers]}` — every child matches
/// - `{"any":[...matchers]}` — at least one child matches
/// - `{"not":{...matcher}}` — child does not match
private indirect enum ToolMatcher: Decodable {
    case leaf(Leaf)
    case all([ToolMatcher])
    case any([ToolMatcher])
    case not(ToolMatcher)

    struct Leaf: Decodable {
        let toolName: String?
        let toolNameContains: String?
        let toolNamePrefix: String?
        let minArgumentsLength: Int?
        let argumentKey: String?
        let argumentPattern: String?
        let argumentExists: Bool?

        enum CodingKeys: String, CodingKey {
            case toolName = "tool_name"
            case toolNameContains = "tool_name_contains"
            case toolNamePrefix = "tool_name_prefix"
            case minArgumentsLength = "min_arguments_length"
            case argumentKey = "argument_key"
            case argumentPattern = "argument_pattern"
            case argumentExists = "argument_exists"
        }

        func matches(event: ToolInvocationEvent, arguments: [String: Any]) -> Bool {
            if let toolName, event.toolName != toolName {
                return false
            }
            if let toolNameContains, !event.toolName.localizedCaseInsensitiveContains(toolNameContains) {
                return false
            }
            if let toolNamePrefix, !event.toolName.hasPrefix(toolNamePrefix) {
                return false
            }
            if let minArgumentsLength, event.argumentsJSON.count < minArgumentsLength {
                return false
            }
            if let argumentKey, let argumentExists {
                let hasKey = arguments[argumentKey] != nil
                if argumentExists != hasKey {
                    return false
                }
            }
            if let argumentKey, let argumentPattern {
                guard let argumentValue = arguments[argumentKey] as? String else {
                    return false
                }
                guard argumentValue.range(of: argumentPattern, options: .regularExpression) != nil else {
                    return false
                }
            }
            return true
        }
    }

    private enum CombinatorKeys: String, CodingKey {
        case all
        case any
        case not
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CombinatorKeys.self)
        if container.contains(.all) {
            self = .all(try container.decode([ToolMatcher].self, forKey: .all))
            return
        }
        if container.contains(.any) {
            self = .any(try container.decode([ToolMatcher].self, forKey: .any))
            return
        }
        if container.contains(.not) {
            self = .not(try container.decode(ToolMatcher.self, forKey: .not))
            return
        }
        self = .leaf(try Leaf(from: decoder))
    }

    func matches(event: ToolInvocationEvent, arguments: [String: Any]) -> Bool {
        switch self {
        case .leaf(let leaf):
            return leaf.matches(event: event, arguments: arguments)
        case .all(let children):
            return !children.isEmpty && children.allSatisfy { $0.matches(event: event, arguments: arguments) }
        case .any(let children):
            return children.contains { $0.matches(event: event, arguments: arguments) }
        case .not(let child):
            return !child.matches(event: event, arguments: arguments)
        }
    }
}

/// Recursive JSON matcher for assistant chunk content (`all` / `any` / `not` + leaf fields).
private indirect enum ContentMatcher: Decodable {
    case leaf(Leaf)
    case all([ContentMatcher])
    case any([ContentMatcher])
    case not(ContentMatcher)

    struct Leaf: Decodable {
        let contentPattern: String?
        let minContentLength: Int?

        enum CodingKeys: String, CodingKey {
            case contentPattern = "content_pattern"
            case minContentLength = "min_content_length"
        }

        func matches(content: String) -> Bool {
            if let minContentLength, content.count < minContentLength {
                return false
            }
            if let contentPattern {
                return content.range(of: contentPattern, options: .regularExpression) != nil
            }
            return true
        }
    }

    private enum CombinatorKeys: String, CodingKey {
        case all
        case any
        case not
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CombinatorKeys.self)
        if container.contains(.all) {
            self = .all(try container.decode([ContentMatcher].self, forKey: .all))
            return
        }
        if container.contains(.any) {
            self = .any(try container.decode([ContentMatcher].self, forKey: .any))
            return
        }
        if container.contains(.not) {
            self = .not(try container.decode(ContentMatcher.self, forKey: .not))
            return
        }
        self = .leaf(try Leaf(from: decoder))
    }

    func matches(content: String) -> Bool {
        switch self {
        case .leaf(let leaf):
            return leaf.matches(content: content)
        case .all(let children):
            return !children.isEmpty && children.allSatisfy { $0.matches(content: content) }
        case .any(let children):
            return children.contains { $0.matches(content: content) }
        case .not(let child):
            return !child.matches(content: content)
        }
    }

    /// Pattern used as redact fallback when outcome omits `pattern`.
    var contentPattern: String? {
        switch self {
        case .leaf(let leaf):
            return leaf.contentPattern
        case .all(let children), .any(let children):
            return children.lazy.compactMap(\.contentPattern).first
        case .not(let child):
            return child.contentPattern
        }
    }
}

/// Recursive JSON matcher for full assistant completions.
private indirect enum CompletionMatcher: Decodable {
    case leaf(Leaf)
    case all([CompletionMatcher])
    case any([CompletionMatcher])
    case not(CompletionMatcher)

    struct Leaf: Decodable {
        let contentPattern: String?
        let minContentLength: Int?
        let detectedPatternsAny: [String]?

        enum CodingKeys: String, CodingKey {
            case contentPattern = "content_pattern"
            case minContentLength = "min_content_length"
            case detectedPatternsAny = "detected_patterns_any"
        }

        func matches(content: String, detectedPatterns: [String]) -> Bool {
            if let minContentLength, content.count < minContentLength {
                return false
            }
            if let contentPattern, content.range(of: contentPattern, options: .regularExpression) == nil {
                return false
            }
            if let detectedPatternsAny, detectedPatternsAny.allSatisfy({ !detectedPatterns.contains($0) }) {
                return false
            }
            return true
        }
    }

    private enum CombinatorKeys: String, CodingKey {
        case all
        case any
        case not
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CombinatorKeys.self)
        if container.contains(.all) {
            self = .all(try container.decode([CompletionMatcher].self, forKey: .all))
            return
        }
        if container.contains(.any) {
            self = .any(try container.decode([CompletionMatcher].self, forKey: .any))
            return
        }
        if container.contains(.not) {
            self = .not(try container.decode(CompletionMatcher.self, forKey: .not))
            return
        }
        self = .leaf(try Leaf(from: decoder))
    }

    func matches(content: String, detectedPatterns: [String]) -> Bool {
        switch self {
        case .leaf(let leaf):
            return leaf.matches(content: content, detectedPatterns: detectedPatterns)
        case .all(let children):
            return !children.isEmpty && children.allSatisfy {
                $0.matches(content: content, detectedPatterns: detectedPatterns)
            }
        case .any(let children):
            return children.contains {
                $0.matches(content: content, detectedPatterns: detectedPatterns)
            }
        case .not(let child):
            return !child.matches(content: content, detectedPatterns: detectedPatterns)
        }
    }

    var contentPattern: String? {
        switch self {
        case .leaf(let leaf):
            return leaf.contentPattern
        case .all(let children), .any(let children):
            return children.lazy.compactMap(\.contentPattern).first
        case .not(let child):
            return child.contentPattern
        }
    }
}

private struct OutcomeRule: Decodable {
    let action: String
    let reason: String?
    let requiredFields: [String]?
    let argumentKey: String?
    let pattern: String?
    let replacement: String?

    enum CodingKeys: String, CodingKey {
        case action
        case reason
        case requiredFields = "required_fields"
        case argumentKey = "argument_key"
        case pattern
        case replacement
    }

    var toolOutcome: ToolGovernanceOutcome {
        switch action.lowercased() {
        case "deny":
            return .deny(reason: reason ?? "Tool invocation denied by policy.")
        case "confirm":
            return .confirm(requiredFields: requiredFields ?? ["user_approval"])
        case "allow":
            return .allow
        case "redact":
            guard let argumentKey, let pattern else {
                return .deny(reason: "Invalid redact outcome for tool rule (missing argument_key/pattern).")
            }
            return .redact(argumentKey: argumentKey, pattern: pattern, replacement: replacement ?? "[REDACTED]")
        default:
            return .deny(reason: "Unknown tool policy action '\(action)'; denying by default.")
        }
    }

    func contentOutcome(fallbackPattern: String?) -> PolicyDecisionOutcome {
        switch action.lowercased() {
        case "deny":
            return .deny(reason: reason ?? "Assistant content denied by policy.")
        case "confirm":
            return .confirm(requiredFields: requiredFields ?? ["review_confirmation"])
        case "allow":
            return .allow
        case "redact":
            let patternToUse = pattern ?? fallbackPattern
            guard let patternToUse else {
                return .deny(reason: "Invalid redact outcome for content rule (missing pattern).")
            }
            return .redact(pattern: patternToUse, replacement: replacement ?? "[REDACTED]")
        default:
            return .deny(reason: "Unknown content policy action '\(action)'; denying by default.")
        }
    }
}

private func parseJSONObject(from json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

/// Detects well-known sensitive categories used by completion matchers and content grants.
public func detectSensitivePatterns(in text: String) -> [String] {
    var detected: [String] = []
    if text.range(of: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}", options: .regularExpression) != nil {
        detected.append("email")
    }
    if text.range(of: "\\b\\d{3}[-.]?\\d{3}[-.]?\\d{4}\\b", options: .regularExpression) != nil {
        detected.append("phone")
    }
    if text.range(of: "\\b\\d{3}-\\d{2}-\\d{4}\\b", options: .regularExpression) != nil {
        detected.append("ssn")
    }
    return detected
}

private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(type, from: data)
}
