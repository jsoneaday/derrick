import Foundation

/// Turns a `plugin.invoke` / `script_exec` JSON result into chat text.
/// Prefix `/plugin-id` skips the LLM, so this must not dump tool/status/exitCode.
public enum PluginInvokePresentation {
    public static let testWirePrefix = "derrick.plugin_test\n"

    public enum Kind: String, Codable, Sendable, Hashable {
        /// Headlines, cards, markdown the user is meant to read.
        case display
        /// Status / success / error — show in a programmatic output box.
        case programmatic
    }

    public struct TestReport: Codable, Sendable, Hashable {
        public var heading: String
        public var body: String
        public var kind: Kind

        public init(heading: String, body: String, kind: Kind) {
            self.heading = heading
            self.body = body
            self.kind = kind
        }
    }

    public static func userFacingText(fromScriptResult raw: String) -> String {
        extractBody(fromScriptResult: raw).text
    }

    /// Host-owned first-run result after promote. Always has a body.
    public static func testReport(pluginID: String, scriptResult raw: String) -> TestReport {
        let extracted = extractBody(fromScriptResult: raw)
        let body = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: Kind = extracted.failed || isProgrammatic(body) ? .programmatic : .display
        return TestReport(
            heading: "Testing new plugin \(pluginID)…",
            body: body.isEmpty ? (extracted.failed ? "failed" : "successful") : body,
            kind: kind
        )
    }

    public static func encodeTestReport(_ report: TestReport) -> String {
        guard let data = try? JSONEncoder().encode(report),
              let json = String(data: data, encoding: .utf8) else {
            return "\(testWirePrefix){\"heading\":\"\(report.heading)\",\"body\":\"\(report.body)\",\"kind\":\"\(report.kind.rawValue)\"}"
        }
        return testWirePrefix + json
    }

    public static func decodeTestReport(_ chunk: String) -> TestReport? {
        guard chunk.hasPrefix(testWirePrefix) else { return nil }
        let json = String(chunk.dropFirst(testWirePrefix.count))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TestReport.self, from: data)
    }

    /// `factory.promote` / `factory.install_sample` JSON after a host test invoke.
    public static func testReport(fromPromoteResult raw: String) -> TestReport? {
        guard let brace = raw.firstIndex(of: "{"),
              let data = String(raw[brace...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let test = obj["test"] as? [String: Any] else {
            return nil
        }
        let heading = test["heading"] as? String ?? "Testing new plugin…"
        let body = test["body"] as? String ?? ""
        let kind = Kind(rawValue: test["kind"] as? String ?? "") ?? .programmatic
        return TestReport(heading: heading, body: body, kind: kind)
    }

    public static func isProgrammatic(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isVacuous(trimmed) { return true }
        if trimmed.localizedCaseInsensitiveCompare("no display content") == .orderedSame {
            return true
        }
        if trimmed.count < 96,
           trimmed.range(
            of: #"^(ok|okay|success|successful|succeeded|connected|done|failed|error|cancelled)\b"#,
            options: [.regularExpression, .caseInsensitive]
           ) != nil {
            return true
        }
        return false
    }

    /// Host tests fail when the plugin ran but produced no useful reading matter.
    public static func isEmptyResult(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isVacuous(trimmed) { return true }
        let lower = trimmed.lowercased()
        if trimmed.count < 180, lower.hasPrefix("no ") {
            return true
        }
        let emptyPhrases = [
            "no matching",
            "no articles found",
            "no headlines",
            "no display content",
            "did not return any text",
            "no news",
            "were available",
            "items were available",
        ]
        return emptyPhrases.contains { lower.contains($0) }
    }

    public static func isVacuous(_ text: String) -> Bool {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return true }
        return lines.allSatisfy { line in
            line.range(of: #"^\d+\.\s*-?\s*$"#, options: .regularExpression) != nil
        }
    }

    private struct Extracted {
        var text: String
        var failed: Bool
    }

    private static func extractBody(fromScriptResult raw: String) -> Extracted {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Extracted(text: "The plugin ran, but it did not return any text.", failed: false)
        }
        if PluginHookPresentation.isHookWire(trimmed) {
            return Extracted(text: trimmed, failed: false)
        }
        if let decoded = decode(trimmed) {
            if decoded.failed {
                return Extracted(text: decoded.errorText, failed: true)
            }
            let body = (decoded.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if isVacuous(body) {
                return Extracted(text: "no display content", failed: false)
            }
            return Extracted(text: body, failed: false)
        }
        if let extracted = stdoutFromSlimDump(trimmed) {
            if isVacuous(extracted) {
                return Extracted(text: "no display content", failed: false)
            }
            return Extracted(text: extracted, failed: false)
        }
        return Extracted(text: trimmed, failed: false)
    }

    private struct ScriptShape: Decodable {
        var status: String?
        var stdout: String?
        var stderr: String?
        var validationFindings: [String]?
        var failureStage: String?
        var exitCode: Int?

        var failed: Bool {
            if let stage = failureStage, stage != "none", !stage.isEmpty { return true }
            if let status, ["failed", "timeout", "blocked"].contains(status) { return true }
            if let exitCode, exitCode != 0 { return true }
            return false
        }

        var errorText: String {
            let findings = (validationFindings ?? []).filter { !$0.isEmpty }
            if let first = findings.first { return first }
            let err = stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !err.isEmpty { return err }
            return "The plugin failed to run."
        }
    }

    private static func decode(_ raw: String) -> ScriptShape? {
        let json: String
        if let brace = raw.firstIndex(of: "{") {
            json = String(raw[brace...])
        } else {
            json = raw
        }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ScriptShape.self, from: data) else {
            return nil
        }
        let looksLikeScript = decoded.stdout != nil
            || decoded.stderr != nil
            || decoded.exitCode != nil
            || decoded.failureStage != nil
            || decoded.status != nil
        return looksLikeScript ? decoded : nil
    }

    private static func stdoutFromSlimDump(_ raw: String) -> String? {
        guard raw.contains("tool:"), raw.contains("stdout:") else { return nil }
        guard let range = raw.range(of: "stdout:") else { return nil }
        return String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
