import Foundation

/// User-facing workflow progress strings shared by MCPService and the UI poll loop.
public enum WorkflowChatProgress: Sendable {
    public static func factoryProgressMessage(from logLine: String) -> String? {
        if logLine.contains("draft_started") {
            for part in logLine.split(separator: " ") {
                guard part.hasPrefix("attempt=") else { continue }
                let spec = part.dropFirst("attempt=".count)
                let numbers = spec.split(separator: "/")
                if numbers.count == 2 {
                    return "Generating plugin draft (attempt \(numbers[0]) of \(numbers[1]))…"
                }
            }
            return "Generating plugin draft…"
        }
        if logLine.contains("direct_test") {
            return "Running plugin tests in Docker…"
        }
        if logLine.contains("review decision=approved") {
            return "Safety review passed."
        }
        if logLine.contains("review decision=rejected") || logLine.contains("review rejected=") {
            return "Safety review requested changes — refining draft…"
        }
        if logLine.contains("attempt="), logLine.contains(" failed=") {
            return "Draft did not pass review — trying again…"
        }
        return nil
    }

    public static func shouldSurfaceWorkflowMessage(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("plugin_factory_build ") || trimmed.hasPrefix("web.crawl ") {
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
}
