import Foundation

/// User-facing workflow progress strings shared by MCPService and the UI poll loop.
public enum WorkflowChatProgress: Sendable {
    public static func factoryProgressMessage(from logLine: String) -> String? {
        let line = logLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if LLMHTTPTimeouts.isTimeoutDescription(line) {
            if line.lowercased().contains("safety reviewer") {
                return "The safety reviewer did not finish in time."
            }
            return "The plugin builder did not finish in time."
        }

        if line.contains("builder_streaming") {
            return "The plugin builder is writing the draft…"
        }
        if line.contains("review_streaming") {
            return "The safety reviewer is writing its decision…"
        }
        if line.contains("review_started") {
            return "Safety reviewer is checking the draft. This can take a few minutes…"
        }
        if line.contains("direct_test_started") {
            return "Running plugin tests in Docker…"
        }
        if line.contains("packaged_test_started") {
            return "Re-testing the packaged plugin…"
        }
        if line.contains("package_started") {
            return "Packaging the plugin…"
        }
        if line.contains("draft_ready") {
            return "Draft received. Checking it…"
        }
        if line.contains("draft_started") {
            if let attempt = attemptLabel(from: line) {
                return "Waiting on the plugin builder (\(attempt)). High thinking can take several minutes…"
            }
            return "Waiting on the plugin builder. High thinking can take several minutes…"
        }
        if line.contains("direct_test") {
            return "Running plugin tests in Docker…"
        }
        if line.contains("review decision=approved") {
            return "Safety review passed."
        }
        if line.contains("review decision=rejected") || line.contains("review rejected=") {
            return "Safety review requested changes. Starting another draft…"
        }
        if line.contains("attempt="), line.contains(" failed=") {
            if let attempt = attemptLabel(from: line) {
                return "That draft did not pass (\(attempt)). Trying again…"
            }
            return "That draft did not pass. Trying again…"
        }
        return nil
    }

    public static func shouldSurfaceWorkflowMessage(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("plugin_factory_build ") || trimmed.hasPrefix("web.crawl ") {
            return false
        }
        if trimmed.hasPrefix("[plugin_factory]") {
            return false
        }
        let technicalPrefixes = [
            "The plugin source",
            "The direct test output",
            "The source uses",
            "The source reads",
        ]
        if technicalPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return false
        }
        return true
    }

    private static func attemptLabel(from logLine: String) -> String? {
        for part in logLine.split(separator: " ") {
            guard part.hasPrefix("attempt=") else { continue }
            let spec = part.dropFirst("attempt=".count)
            let numbers = spec.split(separator: "/")
            guard numbers.count == 2 else { continue }
            return "attempt \(numbers[0]) of \(numbers[1])"
        }
        return nil
    }
}
