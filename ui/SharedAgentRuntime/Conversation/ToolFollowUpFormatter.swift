import Foundation
import MemorySystem
import MCPToolCatalog

/// Builds slim tool payloads for the next agent turn.
/// Full tool JSON stays in debug logs and `ToolCallRecord.result`; only this formatter shapes model context.
enum ToolFollowUpFormatter {
    /// Soft cap for stdout (and generic result text) in follow-up prompts.
    static let defaultStdoutCap = 4_000

    /// One-line description of the tool request (no full script / large args).
    static func slimToolRequestLine(records: [ToolCallRecord]) -> String {
        guard !records.isEmpty else { return "(none)" }
        return records.map { slimRequestDescription(name: $0.name, arguments: $0.arguments) }.joined(separator: "; ")
    }

    /// Slim multi-tool follow-up body from full records.
    static func slimToolResults(records: [ToolCallRecord], stdoutCap: Int = defaultStdoutCap) -> String {
        guard !records.isEmpty else { return "(no tool result)" }
        return records
            .map { slim(toolName: $0.name, rawResult: $0.result ?? "", stdoutCap: stdoutCap) }
            .joined(separator: "\n---\n")
    }

    /// Slim a single tool name + raw MCP text result for agent context.
    static func slim(toolName: String, rawResult: String, stdoutCap: Int = defaultStdoutCap) -> String {
        let trimmed = rawResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return """
            tool: \(toolName)
            status: unknown
            result: (empty)
            """
        }

        // Prefer structured script_exec JSON when present.
        if let script = decodeScriptResult(from: trimmed) {
            return formatScriptResult(toolName: toolName, result: script, stdoutCap: stdoutCap)
        }

        // Fallback: strip wrapper noise and cap opaque text (never pass raw multi-kb JSON dumps when possible).
        let cleaned = stripWrapperLines(from: trimmed)
        let capped = cap(cleaned, maxChars: stdoutCap)
        return """
        tool: \(toolName)
        result:
        \(capped)
        """
    }

    // MARK: - Request description

    static func slimRequestDescription(name: String, arguments: [String: String]) -> String {
        if AllowedMCPTool.isScriptExec(name) || name.hasSuffix("script_exec") {
            return slimScriptRequestDescription(name: name, arguments: arguments)
        }
        return slimGenericRequestDescription(name: name, arguments: arguments)
    }

    private static func slimScriptRequestDescription(name: String, arguments: [String: String]) -> String {
        var parts: [String] = [name]
        if let allowNetwork = arguments["allow_network"] ?? arguments["allowNetwork"] {
            parts.append("allow_network=\(allowNetwork)")
        }
        if let dependencies = arguments["dependencies"],
           !dependencies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           dependencies != "{}" {
            parts.append("dependencies=unsupported")
        }
        if let script = arguments["script"] {
            let lineCount = max(1, script.split(separator: "\n", omittingEmptySubsequences: false).count)
            parts.append("script_lines=\(lineCount)")
        } else if let description = arguments["description"], !description.isEmpty {
            parts.append(shortPreview(description, maxChars: 80))
        }
        return parts.joined(separator: " ")
    }

    private static func slimGenericRequestDescription(name: String, arguments: [String: String]) -> String {
        if arguments.isEmpty { return name }
        let keys = arguments.keys.sorted().joined(separator: ",")
        // Avoid re-pasting large values.
        let largeKeys = arguments.filter { $0.value.count > 120 }.map(\.key).sorted()
        if largeKeys.isEmpty {
            let pairs = arguments.keys.sorted().prefix(6).compactMap { key -> String? in
                guard let value = arguments[key] else { return nil }
                return "\(key)=\(shortPreview(value, maxChars: 40))"
            }
            if pairs.isEmpty { return name }
            return "\(name) (\(pairs.joined(separator: ", ")))"
        }
        return "\(name) (args: \(keys); large omitted: \(largeKeys.joined(separator: ",")))"
    }

    // MARK: - Script result

    /// Fields we care about for agent context (ignores timing/reviewer/verifier).
    struct ScriptSlimDecode: Decodable, Equatable {
        var status: String?
        var failureStage: String?
        var stdout: String?
        var stderr: String?
        var exitCode: Int32?
        var timedOut: Bool?
        var validationFindings: [String]?
    }

    static func decodeScriptResult(from raw: String) -> ScriptSlimDecode? {
        // result may be prefixed with "toolName: " from some summary paths
        let jsonCandidate: String
        if let brace = raw.firstIndex(of: "{") {
            jsonCandidate = String(raw[brace...])
        } else {
            jsonCandidate = raw
        }
        guard let data = jsonCandidate.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ScriptSlimDecode.self, from: data) else { return nil }
        // Require at least one execution-shaped field so random JSON objects are not treated as script results.
        let looksLikeScript =
            decoded.stdout != nil
            || decoded.stderr != nil
            || decoded.exitCode != nil
            || decoded.timedOut != nil
            || decoded.failureStage != nil
            || (decoded.status.map { ["completed", "failed", "timeout", "blocked"].contains($0) } ?? false)
        return looksLikeScript ? decoded : nil
    }

    static func formatScriptResult(toolName: String, result: ScriptSlimDecode, stdoutCap: Int) -> String {
        var lines: [String] = ["tool: \(toolName)"]

        if let status = result.status, !status.isEmpty {
            lines.append("status: \(status)")
        }
        if let stage = result.failureStage, !stage.isEmpty, stage != "none" {
            lines.append("failureStage: \(stage)")
        }
        if let exitCode = result.exitCode {
            lines.append("exitCode: \(exitCode)")
        }
        if let timedOut = result.timedOut {
            lines.append("timedOut: \(timedOut)")
        }

        let findings = (result.validationFindings ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let showFindingsDespiteStdout = result.failureStage == "containerLease"
        // Surface findings when blocked/failed pre-run, or when lease TTL explains a stopped run.
        if !findings.isEmpty, showFindingsDespiteStdout || result.stdout?.isEmpty != false {
            lines.append("findings:")
            for finding in findings.prefix(8) {
                lines.append("- \(finding)")
            }
        }

        let cleanedStdout = stripWrapperLines(from: result.stdout ?? "")
        if !cleanedStdout.isEmpty {
            lines.append("stdout:")
            lines.append(cap(cleanedStdout, maxChars: stdoutCap))
        }

        let cleanedStderr = stripWrapperLines(from: result.stderr ?? "")
        if !cleanedStderr.isEmpty {
            lines.append("stderr:")
            lines.append(cap(cleanedStderr, maxChars: stdoutCap))
        }

        if cleanedStdout.isEmpty && cleanedStderr.isEmpty && findings.isEmpty {
            lines.append("result: (no stdout/stderr)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Text hygiene

    /// Drop container wrapper / timing lines that are not user-facing tool output.
    static func stripWrapperLines(from text: String) -> String {
        guard !text.isEmpty else { return text }
        let filtered = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            if trimmed.hasPrefix("[script_exec]") { return false }
            if trimmed.hasPrefix("[TIME_METRIC]") { return false }
            return true
        }
        return filtered
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cap(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "…[truncated]…" }
        if text.count <= maxChars { return text }
        let idx = text.index(text.startIndex, offsetBy: maxChars)
        return String(text[..<idx]) + "\n…[truncated]…"
    }

    private static func shortPreview(_ value: String, maxChars: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count <= maxChars { return singleLine }
        let idx = singleLine.index(singleLine.startIndex, offsetBy: maxChars)
        return String(singleLine[..<idx]) + "…"
    }
}
