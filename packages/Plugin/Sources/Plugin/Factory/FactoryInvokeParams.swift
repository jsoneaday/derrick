import Foundation

/// Params for factory.test and the live check after install.
/// Schema and fixtures win when they carry typed values; otherwise keys in `handle` get typed defaults.
/// Unknown keys are omitted — a wrong type is worse than no param.
public enum FactoryInvokeParams: Sendable {
    public static let placeholderKey = "sample"

    public enum Kind: String, Sendable, Equatable {
        case string
        case number
        case bool
        case stringList
        case numberList
    }

    public static func parseFixtureParams(_ json: String) -> [[String: PluginJSON]] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        guard let list = try? JSONDecoder().decode([PluginJSON].self, from: data) else { return [] }
        return list.compactMap { item in
            guard case .object(let object) = item else { return nil }
            if case .object(let params) = object["params"] { return params }
            return [:]
        }
    }

    public static func parseSchema(_ json: String) -> [String: Kind] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [:] }
        if let object = try? JSONDecoder().decode([String: String].self, from: data) {
            var out: [String: Kind] = [:]
            for (key, raw) in object {
                if let kind = kind(fromDeclared: raw) { out[key] = kind }
            }
            return out
        }
        return [:]
    }

    public static func isPlaceholder(_ params: [String: PluginJSON]) -> Bool {
        if params.isEmpty { return true }
        return params.count == 1 && params[placeholderKey] != nil
    }

    public static func referencedKeys(in handle: String) -> [String] {
        Array(PluginParamsContract.declaredKinds(handle).keys)
    }

    public static func kind(
        for key: String,
        handle: String = "",
        schema: [String: Kind] = [:]
    ) -> Kind? {
        if let declared = schema[key] { return declared }
        return PluginParamsContract.declaredKinds(handle)[key]
    }

    public static func defaultValue(
        for key: String,
        goal: String,
        handle: String = "",
        schema: [String: Kind] = [:]
    ) -> PluginJSON? {
        guard let kind = kind(for: key, handle: handle, schema: schema) else { return nil }
        switch kind {
        case .bool:
            return .bool(true)
        case .number:
            return .number(5)
        case .stringList:
            return .array([.string(representativeTopic(from: goal))])
        case .numberList:
            return .array([.number(5)])
        case .string:
            return .string(representativeTopic(from: goal))
        }
    }

    public static func inferred(
        handle: String,
        goal: String,
        schema: [String: Kind] = [:]
    ) -> [String: PluginJSON] {
        var params: [String: PluginJSON] = [:]
        let keys = Set(PluginParamsContract.declaredKinds(handle).keys).union(schema.keys)
        for key in keys where key != placeholderKey {
            if let value = defaultValue(for: key, goal: goal, handle: handle, schema: schema) {
                params[key] = value
            }
        }
        return params
    }

    /// Use fixtures the package actually wrote. Do not invent params from the goal.
    public static func resolve(
        fixturesJSON: String,
        handle: String,
        goal: String,
        schemaJSON: String = ""
    ) -> [String: PluginJSON] {
        let schema = parseSchema(schemaJSON)
        if let first = parseFixtureParams(fixturesJSON).first, !isPlaceholder(first) {
            return normalize(first, handle: handle, goal: goal, schema: schema)
        }
        return [:]
    }

    /// Coerce existing keys to the expected type. Do not invent extra keys.
    public static func normalize(
        _ params: [String: PluginJSON],
        handle: String,
        goal: String,
        schema: [String: Kind] = [:]
    ) -> [String: PluginJSON] {
        var out: [String: PluginJSON] = [:]
        for (key, raw) in params where key != placeholderKey {
            let expected = kind(for: key, handle: handle, schema: schema)
            if let expected, let coerced = coerce(raw, to: expected) {
                out[key] = coerced
                continue
            }
            if expected != nil, let fallback = defaultValue(for: key, goal: goal, handle: handle, schema: schema) {
                out[key] = fallback
            }
        }
        return out
    }

    public static func encodeFixtures(_ params: [String: PluginJSON]) -> String {
        let item = PluginJSON.object([
            "kind": .string("test"),
            "params": .object(params),
        ])
        guard let data = try? JSONEncoder().encode([item]),
              let json = String(data: data, encoding: .utf8) else {
            return FactoryPackageDraft.defaultFixturesJSON
        }
        return json
    }

    public static func testHeading(pluginID: String, params: [String: PluginJSON]) -> String {
        let pairs = params.keys.sorted().compactMap { key -> String? in
            guard key != placeholderKey, let rendered = render(params[key]) else { return nil }
            return "\(key)=\(rendered)"
        }
        if pairs.isEmpty {
            return "Testing new plugin \(pluginID)…"
        }
        return "Testing new plugin \(pluginID) (\(pairs.joined(separator: ", ")))…"
    }

    /// `/plugin-id topic 8` → text, topic, and max/limit.
    public static func chatParams(remainder: String) -> [String: PluginJSON] {
        let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        var params: [String: PluginJSON] = [
            "text": .string(trimmed),
            "topic": .string(trimmed),
        ]
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count >= 2, let number = Int(parts[parts.count - 1]), number > 0 {
            params["max"] = .number(Double(number))
            params["limit"] = .number(Double(number))
            let topic = parts.dropLast().joined(separator: " ")
            params["topic"] = .string(topic)
        }
        return params
    }

    public static func representativeTopic(from goal: String) -> String {
        let pattern = #"[\"“]([^\"”]{2,40})[\"”]"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(goal.startIndex..<goal.endIndex, in: goal)
            if let match = regex.firstMatch(in: goal, range: range),
               match.numberOfRanges >= 2,
               let inner = Range(match.range(at: 1), in: goal) {
                let value = String(goal[inner]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return "technology"
    }

    private static func kind(fromDeclared raw: String) -> Kind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "string", "text":
            return .string
        case "number", "int", "integer", "float":
            return .number
        case "bool", "boolean":
            return .bool
        case "string[]", "array", "list", "strings":
            return .stringList
        case "number[]":
            return .numberList
        default:
            return nil
        }
    }

    private static func coerce(_ value: PluginJSON, to kind: Kind) -> PluginJSON? {
        switch kind {
        case .string:
            if case .string(let text) = value, !text.isEmpty { return value }
            if case .number(let number) = value { return .string(render(.number(number)) ?? "") }
            return nil
        case .number:
            if case .number = value { return value }
            if case .string(let text) = value, let number = Double(text), number.isFinite {
                return .number(number)
            }
            return nil
        case .bool:
            if case .bool = value { return value }
            return nil
        case .stringList:
            if case .array(let items) = value {
                let strings = items.compactMap { item -> PluginJSON? in
                    if case .string(let text) = item, !text.isEmpty { return .string(text) }
                    return nil
                }
                return strings.isEmpty ? nil : .array(strings)
            }
            if case .string(let text) = value {
                let parts = text.split(whereSeparator: { $0 == "," || $0 == "|" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if parts.count > 1 { return .array(parts.map { .string($0) }) }
            }
            return nil
        case .numberList:
            if case .array(let items) = value {
                let numbers = items.compactMap { item -> PluginJSON? in
                    if case .number = item { return item }
                    if case .string(let text) = item, let number = Double(text), number.isFinite {
                        return .number(number)
                    }
                    return nil
                }
                return numbers.isEmpty ? nil : .array(numbers)
            }
            return nil
        }
    }

    private static func render(_ value: PluginJSON?) -> String? {
        switch value {
        case .string(let text):
            return text
        case .number(let number):
            if number.rounded() == number {
                return String(Int(number))
            }
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .array(let items):
            let parts = items.compactMap { render($0) }
            return "[\(parts.joined(separator: ","))]"
        default:
            return nil
        }
    }
}
