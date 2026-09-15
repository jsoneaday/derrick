import Foundation

/// Why Access docs lookup failed. Wire value on `ConnectorAuthDiscoverResult`.
public enum PluginDocsLookupFailure: String, Sendable, Hashable, Codable, Error {
    case webToolsNotReady = "web_tools_not_ready"
    case searchEmpty = "search_empty"
    case crawlFailed = "crawl_failed"
    case emptyNotes = "empty_notes"
}

/// Access ask: wait for a docs summary, then ask from that summary plus the docs link.
public enum PluginAccessAskPolicy: Sendable {
    public static let genericQuestion =
        "Can Derrick reach that now, or is it blocked (login, paywall, or missing files)?"

    public static let reviewingQuestion =
        "Checking the setup docs for that source. Derrick will ask what you need once those notes are in."

    public static let reviewingStatusLabel = "Checking setup docs"

    public static let docsURLFindQuestion =
        "Derrick could not find the API setup docs for that source. Paste the page that explains how apps authenticate (a token, key, or login)."

    public static let webToolsNotReadyQuestion =
        "Derrick could not search the web because its web tools were not ready. Keep Docker Desktop open and try again in a moment, or paste the page that explains how apps authenticate (a token, key, or login)."

    public static let summaryCharacterLimit = 280

    /// First search/crawl miss asks the user for a URL. Name the page Derrick tried.
    /// Blame a paste only when the user supplied that URL.
    public static func docsURLQuestion(
        triedURL: String? = nil,
        fromHuman: Bool = false,
        failure: PluginDocsLookupFailure? = nil
    ) -> String {
        if failure == .webToolsNotReady {
            return webToolsNotReadyQuestion
        }
        let url = triedURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !url.isEmpty else { return docsURLFindQuestion }
        let link = "[\(url)](\(url))"
        if fromHuman {
            return "Derrick could not use \(link) as API setup docs. Paste a different page that explains how apps authenticate (a token, key, or login)."
        }
        return "Derrick looked at \(link) but could not use it as API setup docs. Paste the page that explains how apps authenticate (a token, key, or login)."
    }

    public static func isDocsSearchRequest(_ text: String) -> Bool {
        if parseHTTPURL(text) != nil { return false }
        let lowered = text.lowercased()
        let phrases = [
            "search",
            "look it up",
            "look up",
            "look for",
            "find the docs",
            "find them",
            "find it",
            "google",
        ]
        return phrases.contains { lowered.contains($0) }
    }

    public static func vendor(
        from connect: PluginConnectBinding?
    ) -> PluginFactoryCreateInput.ConnectorVendor? {
        guard let connect else { return nil }
        let draft = PluginSkillDraft(goal: connect.detail, purpose: connect.detail)
        return PluginSkillDraftPlanner.inferConnectorVendor(from: draft)
    }

    public static func documentationURL(from connect: PluginConnectBinding?) -> String? {
        parseHTTPURL(connect?.detail)
    }

    public static func parseHTTPURL(_ text: String?) -> String? {
        guard let text else { return nil }
        let pattern = #"https?://[^\s]+"#
        guard let match = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(text[match]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);"))
    }

    public static func hasUsableDocs(_ discovery: ConnectorAuthDiscovery) -> Bool {
        if let hint = discovery.setupHint, hint.count >= 12 { return true }
        if let crawl = discovery.crawlSummary, crawl.count >= 24 { return true }
        return false
    }

    /// Lookup failure always wins over a guessed auth hint.
    public static func docsReviewSucceeded(
        failure: PluginDocsLookupFailure?,
        auth: ConnectorAuthDiscovery
    ) -> Bool {
        failure == nil && hasUsableDocs(auth)
    }

    public static func question(
        connect: PluginConnectBinding?,
        discovery: ConnectorAuthDiscovery?,
        documentationURL: String? = nil
    ) -> String {
        let url = documentationURL ?? self.documentationURL(from: connect)
        guard let discovery else {
            if connect?.klass == .localFiles {
                return genericQuestion
            }
            return reviewingQuestion
        }
        return question(
            fromDocs: discovery.preferringCallCredential(),
            documentationURL: url
        )
    }

    public static func question(
        fromDocs discovery: ConnectorAuthDiscovery,
        documentationURL: String?
    ) -> String {
        var lines: [String] = []
        if let need = neededSecretSentence(discovery) {
            lines.append(need)
        } else if let detail = docsDetail(discovery) {
            lines.append(detail)
        } else {
            lines.append("The setup docs name a token or key Derrick will need to reach that source.")
        }
        if !discovery.secrets.isEmpty {
            lines.append("Derrick will keep it on this Mac. It never goes into the plugin.")
        }
        if let documentationURL, !documentationURL.isEmpty {
            lines.append("[Read the setup docs](\(documentationURL))")
        }
        lines.append("If you already have that, say yes. If you still need to create it, say so.")
        return lines.joined(separator: "\n\n")
    }

    private static func neededSecretSentence(_ discovery: ConnectorAuthDiscovery) -> String? {
        let labels = discovery.secrets.map(\.label).filter { !$0.isEmpty }
        if labels.count == 1 {
            let label = labels[0].lowercased()
            return "To connect, Derrick needs \(indefiniteArticle(for: label)) \(label)."
        }
        if labels.count > 1 {
            let listed = labels.dropLast().joined(separator: ", ")
            return "To connect, Derrick needs \(listed.lowercased()) and \(labels.last!.lowercased())."
        }
        return nil
    }

    private static func docsDetail(_ discovery: ConnectorAuthDiscovery) -> String? {
        if let hint = discovery.setupHint, !hint.isEmpty {
            return hint
        }
        if let crawl = discovery.crawlSummary, !crawl.isEmpty {
            return clip(crawl, limit: summaryCharacterLimit)
        }
        let labels = discovery.secrets.map(\.label).filter { !$0.isEmpty }
        if labels.count == 1 {
            return "The setup docs say Derrick needs a \(labels[0].lowercased())."
        }
        if labels.count > 1 {
            return "The setup docs say Derrick needs \(labels.joined(separator: " and ").lowercased())."
        }
        return nil
    }

    public static func collectableSecrets(
        _ discovery: ConnectorAuthDiscovery?
    ) -> [PluginSecretField] {
        guard let discovery else { return [] }
        return discovery.preferringCallCredential().secrets
    }

    public static func needsCredentialForm(_ discovery: ConnectorAuthDiscovery?) -> Bool {
        !collectableSecrets(discovery).isEmpty
    }

    public static func credentialFormQuestion(discovery: ConnectorAuthDiscovery?) -> String {
        if let field = collectableSecrets(discovery).first {
            let label = field.label.lowercased()
            return "Enter the \(label) in the form Derrick opened. Derrick will keep it on this Mac. It never goes into the plugin."
        }
        return "Enter the token or key in the form Derrick opened. Derrick will keep it on this Mac. It never goes into the plugin."
    }

    public static func credentialFormPrompt(discovery: ConnectorAuthDiscovery?) -> String {
        let secrets = collectableSecrets(discovery)
        var lines: [String] = []
        if let hint = discovery?.preferringCallCredential().setupHint,
           hintMatchesCallSecrets(hint, secrets: secrets) {
            lines.append(hint)
        } else if let field = secrets.first {
            lines.append("Enter the \(field.label.lowercased()) Derrick needs to call that service.")
        } else {
            lines.append("Enter the token or key Derrick needs to call that service.")
        }
        lines.append("Derrick will keep it on this Mac. It never goes into the plugin.")
        return lines.joined(separator: "\n\n")
    }

    private static func hintMatchesCallSecrets(_ hint: String, secrets: [PluginSecretField]) -> Bool {
        let lowered = hint.lowercased()
        let mentionsInstall = ["client id", "client secret", "consumer key", "oauth"].contains {
            lowered.contains($0)
        }
        let mentionsSecret = secrets.contains { secret in
            let label = secret.label.lowercased()
            return !label.isEmpty && lowered.contains(label)
        }
        if mentionsInstall && !mentionsSecret {
            return false
        }
        return mentionsSecret
    }

    public static func isCredentialAffirmation(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("don't have") || lowered.contains("do not have")
            || lowered.contains("dont have") {
            return false
        }
        let phrases = [
            "i have",
            "i've got",
            "already have",
            "i do",
            "yes",
            "yep",
            "yeah",
            "got it",
        ]
        return phrases.contains { lowered.contains($0) }
    }

    private static func indefiniteArticle(for noun: String) -> String {
        guard let first = noun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first else {
            return "a"
        }
        return "aeiou".contains(first) ? "an" : "a"
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
