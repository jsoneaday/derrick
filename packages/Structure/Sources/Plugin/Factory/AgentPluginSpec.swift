import Foundation

/// Canonical Agent Plugins package format — always prefer the live published document.
public enum AgentPluginSpec: Sendable {
    /// Published specification (source of truth).
    public static let publishedURL = URL(string: "https://agent-plugins.org/specification")!

    public static let preferLatestDisclaimer = """
    Prefer the latest published Agent Plugins Specification over any cached or bundled copy. \
    If this summary disagrees with https://agent-plugins.org/specification, follow the live document.
    """

    /// Condensed package rules used only when the live fetch fails.
    public static func bundledFallbackSummary() -> String {
        """
        Agent Plugins package model (bundled fallback — verify against the live spec):
        - Distributable plugin is a directory (or archive) with a root plugin.json manifest.
        - Manifest names the plugin and declares components (skills, agents, commands, hooks, mcpServers, etc.).
        - Skills live under skills/<name>/ and MUST include SKILL.md (YAML frontmatter name + description, then instructions).
        - Optional progressive-disclosure files may live under skills/<name>/references/.
        - Clients discover components from the manifest; do not invent a proprietary package layout.
        - Derrick host writes plugin.json for connectors; guest Go + required SKILL.md still ship in the package.
        """
    }

    /// Host-forced block injected into builder/reviewer goals.
    public static func forcedPromptBlock(summary: String, sourceURL: String?) -> String {
        let clipped = String(summary.prefix(6_000))
        let source = sourceURL ?? publishedURL.absoluteString
        return """
        --- Agent Plugins Specification (host-enforced) ---
        \(preferLatestDisclaimer)
        Source: \(source)

        \(clipped)
        --- end Agent Plugins Specification ---
        Obey this package model. Include at least one skills/<name>/SKILL.md. Do not invent app.derrick/runtime.json.
        """
    }

    /// Extract usable text from a web.crawl tool result for the specification page.
    public static func summary(fromCrawlToolText text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        if let outcome = ToolExecutionOutcome.decode(from: text),
           let value = outcome.output?.value {
            return summary(fromCrawlPayload: value)
        }
        return summary(fromCrawlPayload: text)
    }

    private static func summary(fromCrawlPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(6_000))
        }
        if let pages = object["pages"] as? [[String: Any]] {
            let chunks = pages.compactMap { page -> String? in
                let title = (page["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let body = (page["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if title.isEmpty, body.isEmpty { return nil }
                if title.isEmpty { return body }
                if body.isEmpty { return title }
                return "\(title)\n\(body)"
            }
            let joined = chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : String(joined.prefix(6_000))
        }
        if let text = object["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(6_000))
        }
        return nil
    }
}
