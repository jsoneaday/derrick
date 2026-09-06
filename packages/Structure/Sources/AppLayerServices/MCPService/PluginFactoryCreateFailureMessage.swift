import Foundation

/// User-facing copy when plugin creation fails before a release is saved.
public struct PluginFactoryCreateFailurePresentation: Sendable, Equatable {
    public let summary: String
    public let technicalDetail: String?

    public init(summary: String, technicalDetail: String?) {
        self.summary = summary
        self.technicalDetail = technicalDetail
    }
}

/// Converts raw plugin-factory workflow errors into copy suitable for the creation wizard.
public enum PluginFactoryCreateFailureMessage: Sendable {
    public static func userFacing(_ raw: String) -> String {
        presentation(raw).summary
    }

    public static func presentation(_ raw: String) -> PluginFactoryCreateFailurePresentation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PluginFactoryCreateFailurePresentation(
                summary: """
                The connector was not saved. Try again.
                """,
                technicalDetail: nil
            )
        }

        if isModelTimeout(trimmed) {
            let reviewer = trimmed.lowercased().contains("safety reviewer")
            return PluginFactoryCreateFailurePresentation(
                summary: reviewer
                    ? """
                    The connector was not saved. The safety reviewer did not finish in time. Try again.
                    """
                    : """
                    The connector was not saved. The plugin builder did not finish in time. \
                    High thinking can take several minutes — try again.
                    """,
                technicalDetail: trimmed
            )
        }

        if isReviewRejection(trimmed) || isTechnicalReviewerDetail(trimmed) {
            return PluginFactoryCreateFailurePresentation(
                summary: """
                The connector was not saved. Derrick built a draft but the safety review could not approve it \
                after several attempts. Try again.
                """,
                technicalDetail: trimmed
            )
        }

        if isDraftValidationDetail(trimmed) || isFactoryDidNotSaveDetail(trimmed) {
            return PluginFactoryCreateFailurePresentation(
                summary: """
                The connector was not saved. Derrick could not finish building it after several attempts. \
                Try again.
                """,
                technicalDetail: trimmed
            )
        }

        if isTechnicalFactoryDetail(trimmed) {
            return PluginFactoryCreateFailurePresentation(
                summary: """
                The connector was not saved. Derrick could not finish building it. Try again.
                """,
                technicalDetail: trimmed
            )
        }

        return PluginFactoryCreateFailurePresentation(
            summary: "The connector was not saved. \(trimmed)",
            technicalDetail: nil
        )
    }

    private static func isModelTimeout(_ message: String) -> Bool {
        LLMHTTPTimeouts.isTimeoutDescription(message)
    }

    private static func isFactoryDidNotSaveDetail(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("did not return a saved connector")
            || lower.contains("plugin factory could not finish")
    }

    private static func isTechnicalFactoryDetail(_ message: String) -> Bool {
        if message.count > 160 { return true }
        let prefixes = [
            "Invalid Agent Plugin manifest",
            "Invalid Python guest source",
            "Python draft test failed",
            "Plugin review rejected",
            "Draft validation failed:",
        ]
        return prefixes.contains(where: { message.hasPrefix($0) })
    }

    private static func isDraftValidationDetail(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.hasPrefix("draft validation failed:") { return true }
        let indicators = [
            "sort http_results",
            "test_input_json must",
            "http_results must include",
            "messaging_ops must declare",
            "messaging_op ",
            "deterministic draft validation",
            "connector test_input_json must",
            "direct test must",
        ]
        return indicators.contains(where: { lower.contains($0) })
    }

    private static func isReviewRejection(_ message: String) -> Bool {
        let lower = message.lowercased()
        let indicators = [
            "direct test output",
            "safety review",
            "approval requires",
            "review rejected",
            "does not cover",
            "test evidence",
            "vendor operations",
            "thread replies",
        ]
        return indicators.contains(where: { lower.contains($0) })
    }

    private static func isTechnicalReviewerDetail(_ message: String) -> Bool {
        if message.contains(";") && message.count > 120 { return true }
        let prefixes = [
            "The plugin source",
            "The direct test output",
            "The source uses",
            "The source reads",
            "The source appears",
            "The connector synchronizes",
        ]
        return prefixes.contains(where: { message.hasPrefix($0) })
    }
}
