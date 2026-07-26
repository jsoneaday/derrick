import Foundation

public struct OnDemandToolGovernancePolicy: ToolGovernancePolicy {
    private let store: any PolicyStore
    private let applicationName: String

    public init(store: any PolicyStore, applicationName: String) {
        self.store = store
        self.applicationName = applicationName
    }

    public func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
        let rules = try await loadRules(scopes: ["tool_invocation", "tool_call"])
        guard !rules.isEmpty else {
            // Fail closed: empty store is a misconfiguration, not an allow-all.
            return .deny(reason: Self.noRulesConfiguredReason)
        }

        let argumentsObject = parseJSONObject(from: event.argumentsJSON)
        for rule in rules {
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
        return loaded.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.createdAt > rhs.createdAt
        }
    }
}

public struct OnDemandCompletionContentPolicy: PolicyEvaluator {
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
        return loaded.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.createdAt > rhs.createdAt
        }
    }
}

private struct ToolMatcher: Decodable {
    let toolName: String?
    let toolNameContains: String?
    let minArgumentsLength: Int?
    let argumentKey: String?
    let argumentPattern: String?
    let argumentExists: Bool?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case toolNameContains = "tool_name_contains"
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

private struct ContentMatcher: Decodable {
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

private struct CompletionMatcher: Decodable {
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

private func detectSensitivePatterns(in text: String) -> [String] {
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
