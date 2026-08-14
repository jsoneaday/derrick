import Foundation
import MCPToolCatalog

/// Classifies structured tool payloads that return success at the MCP transport layer but failed logically.
public enum MCPToolOutcomeSemantics: Sendable {
    public static func isError(toolName: String, text: String, transportIsError: Bool) -> Bool {
        if transportIsError { return true }
        if AllowedMCPTool.isScriptExec(toolName) {
            return ScriptExecutionResult.indicatesFailure(inJSON: text)
        }
        return false
    }

    public static func errorMessage(toolName: String, text: String) -> String? {
        if AllowedMCPTool.isScriptExec(toolName) {
            return ScriptExecutionResult.failureSummary(inJSON: text)
        }
        return nil
    }
}

extension ScriptExecutionResult {
    /// True when the payload reports a blocked, failed, or timed-out run (not a transport-level MCP error).
    public var indicatesToolError: Bool {
        failureStage != .none || status != .completed
    }

    public static func decode(fromJSON text: String) -> ScriptExecutionResult? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ScriptExecutionResult.self, from: data)
    }

    public static func indicatesFailure(inJSON text: String) -> Bool {
        decode(fromJSON: text)?.indicatesToolError ?? false
    }

    public static func failureSummary(inJSON text: String) -> String? {
        decode(fromJSON: text)?.failureSummary
    }

    /// Short human-readable detail for job failure / tool error messages.
    public var failureSummary: String? {
        guard indicatesToolError else { return nil }
        let stderrTrim = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderrTrim.isEmpty { return stderrTrim }
        let findings = validationFindings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !findings.isEmpty { return findings.joined(separator: "; ") }
        return "status=\(status.rawValue) stage=\(failureStage.rawValue)"
    }
}
