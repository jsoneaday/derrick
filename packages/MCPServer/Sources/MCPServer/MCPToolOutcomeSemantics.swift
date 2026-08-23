import ServiceContracts

/// Classifies structured tool payloads that return success at the MCP transport layer but failed logically.
public enum MCPToolOutcomeSemantics: Sendable {
    public static func isError(toolName: String, text: String, transportIsError: Bool) -> Bool {
        if transportIsError { return true }
        if let outcome = ToolExecutionOutcome.decode(from: text) {
            return outcome.indicatesFailure
        }
        return false
    }

    public static func errorMessage(toolName: String, text: String) -> String? {
        if let outcome = ToolExecutionOutcome.decode(from: text) {
            return outcome.failureSummary
        }
        return nil
    }
}
