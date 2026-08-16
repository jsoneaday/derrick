import Foundation

/// Factory plugins must declare `PluginParams` with base TypeScript types only.
public enum PluginParamsContract: Sendable {
    public static func validate(_ script: String) -> [String] {
        var findings: [String] = PluginTypeSafety.findings(in: script)
        guard let body = paramsBody(in: script) else {
            findings.append(
                "Declare `interface PluginParams {}`. Leave it empty if the plugin has no parameters. Named fields must be string, number, boolean, string[], or number[]."
            )
            return findings
        }
        if script.range(
            of: #"HandleEvent\s*<\s*PluginParams\s*>"#,
            options: .regularExpression
        ) == nil {
            findings.append("handle must take `event: HandleEvent<PluginParams>`.")
        }
        if body.range(of: #"\[\s*[A-Za-z_]"#, options: .regularExpression) != nil
            || body.range(of: #"Record\s*<"#, options: .regularExpression) != nil
            || script.range(of: #"type\s+PluginParams\s*=\s*Record\s*<"#, options: .regularExpression) != nil {
            findings.append(
                "PluginParams cannot use an index signature or Record. Use named fields of string, number, boolean, string[], or number[], or leave PluginParams empty."
            )
        }
        findings.append(contentsOf: fieldFindings(in: body))
        return findings
    }

    public static func declaredKinds(_ script: String) -> [String: FactoryInvokeParams.Kind] {
        guard let body = paramsBody(in: script) else { return [:] }
        var kinds: [String: FactoryInvokeParams.Kind] = [:]
        for (name, type) in fields(in: body) {
            if let kind = kind(fromType: type) {
                kinds[name] = kind
            }
        }
        return kinds
    }

    private static func paramsBody(in script: String) -> String? {
        let patterns = [
            #"interface\s+PluginParams\s*\{"#,
            #"type\s+PluginParams\s*=\s*\{"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: script,
                    range: NSRange(script.startIndex..<script.endIndex, in: script)
                  ),
                  let end = Range(match.range, in: script) else { continue }
            return balancedBody(after: end.upperBound, in: script)
        }
        return nil
    }

    private static func balancedBody(after start: String.Index, in script: String) -> String? {
        var depth = 1
        var index = start
        while index < script.endIndex {
            let ch = script[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(script[start..<index])
                }
            }
            index = script.index(after: index)
        }
        return nil
    }

    private static func fields(in body: String) -> [(String, String)] {
        let pattern = #"([A-Za-z_][A-Za-z0-9_]*)\s*\??\s*:\s*([^;]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var fields: [(String, String)] = []
        regex.enumerateMatches(in: body, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 3,
                  let nameRange = Range(match.range(at: 1), in: body),
                  let typeRange = Range(match.range(at: 2), in: body) else { return }
            let name = String(body[nameRange])
            let type = String(body[typeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            fields.append((name, type))
        }
        return fields
    }

    private static func fieldFindings(in body: String) -> [String] {
        fields(in: body).compactMap { name, type in
            kind(fromType: type) == nil
                ? "PluginParams.\(name) must be a base type (string, number, boolean, string[], number[]). Found `\(type)`."
                : nil
        }
    }

    private static func kind(fromType raw: String) -> FactoryInvokeParams.Kind? {
        switch raw.replacingOccurrences(of: " ", with: "").lowercased() {
        case "string":
            return .string
        case "number":
            return .number
        case "boolean":
            return .bool
        case "string[]", "array<string>", "readonlystring[]":
            return .stringList
        case "number[]", "array<number>", "readonlynumber[]":
            return .numberList
        default:
            return nil
        }
    }
}
