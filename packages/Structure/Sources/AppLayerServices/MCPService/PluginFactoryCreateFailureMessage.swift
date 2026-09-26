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

        if alreadyExplained(trimmed) {
            return PluginFactoryCreateFailurePresentation(summary: trimmed, technicalDetail: nil)
        }

        if ModelProviderLimit.matches(trimmed) {
            return PluginFactoryCreateFailurePresentation(
                summary: ModelProviderLimit.summary,
                technicalDetail: trimmed
            )
        }

        let nature = excerpt(trimmed)
        let unchanged = nature == collapse(trimmed)
        return PluginFactoryCreateFailurePresentation(
            summary: "The connector was not saved. \(nature)",
            technicalDetail: unchanged ? nil : trimmed
        )
    }

    private static let excerptLimit = 360

    /// A readable slice of the actual error. Every failure keeps its own reason.
    private static func excerpt(_ raw: String) -> String {
        let collapsed = collapse(raw)
        guard collapsed.count > excerptLimit else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: excerptLimit)
        let head = collapsed[..<end]
        if let space = head.lastIndex(of: " "), space > head.startIndex {
            return String(head[..<space]) + "…"
        }
        return String(head) + "…"
    }

    private static func collapse(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func alreadyExplained(_ message: String) -> Bool {
        message.hasPrefix("The connector was not saved.")
    }
}
