import Foundation
import MemorySystem
import MCPToolCatalog
import ServiceContracts

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

        if let outcome = ToolExecutionOutcome.decode(from: trimmed) {
            return formatOutcome(toolName: toolName, outcome: outcome, stdoutCap: stdoutCap)
        }

        return "tool: \(toolName)\nresult:\n\(cap(trimmed, maxChars: stdoutCap))"
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

    static func formatOutcome(
        toolName: String,
        outcome: ToolExecutionOutcome,
        stdoutCap: Int
    ) -> String {
        var lines = [
            "tool: \(toolName)",
            "status: \(outcome.status.rawValue)",
            "stage: \(outcome.stage.rawValue)",
        ]
        if let exitCode = outcome.exitCode {
            lines.append("exitCode: \(exitCode)")
        }
        if outcome.timedOut {
            lines.append("timedOut: true")
        }
        if let durationMS = outcome.durationMS {
            lines.append("durationMS: \(durationMS)")
        }
        if let retry = outcome.retry {
            lines.append(
                "retry: allowed=\(retry.allowed)" +
                (retry.attempt.map { " attempt=\($0)" } ?? "") +
                (retry.maxAttempts.map { " maxAttempts=\($0)" } ?? "")
            )
        }
        if !outcome.diagnostics.isEmpty {
            lines.append("diagnostics:")
            for diagnostic in outcome.diagnostics.prefix(8) {
                lines.append("- [\(diagnostic.severity.rawValue)] \(diagnostic.message)")
            }
        }
        if let output = outcome.output, !output.value.isEmpty {
            lines.append("output format: \(output.format.rawValue)")
            lines.append("output:")
            lines.append(cap(output.value, maxChars: stdoutCap))
        }
        if outcome.output == nil && outcome.diagnostics.isEmpty {
            lines.append("result: (no output or diagnostics)")
        }
        return lines.joined(separator: "\n")
    }

    /// Ensures a failed script's actionable findings reach the user even if the
    /// follow-up model omits them from its final prose response.
    static func appendingFailureDetails(
        to response: String,
        records: [ToolCallRecord]
    ) -> String {
        guard let record = records.reversed().first(where: {
            guard let result = $0.result else { return false }
            return ToolExecutionOutcome.decode(from: result) != nil
        }),
        let rawResult = record.result,
        let details = failureDetails(from: rawResult)
        else {
            return response
        }

        let reasons = details.reasons
        let responseAlreadyIncludesReasons = reasons.allSatisfy { response.contains($0) }
        guard !responseAlreadyIncludesReasons else { return response }

        let reasonLines = reasons
            .prefix(8)
            .map { "- \($0)" }
            .joined(separator: "\n")
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\nTool failure details:\n"
            + "- Failure stage: \(details.stage)\n"
            + reasonLines
    }

    private static func failureDetails(
        from rawResult: String
    ) -> (stage: String, reasons: [String])? {
        guard let outcome = ToolExecutionOutcome.decode(from: rawResult),
              outcome.indicatesFailure else {
            return nil
        }
        let reasons = outcome.diagnostics
            .map(\.message)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (
            outcome.stage.rawValue,
            reasons.isEmpty ? ["No diagnostic detail was returned."] : reasons
        )
    }

    // MARK: - Text sizing

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
