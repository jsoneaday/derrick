import Foundation

/// Turns a source name plus DuckDuckGo hits into one docs URL. No vendor URL table.
public enum VendorDocsLocator: Sendable {
    public struct Hit: Sendable, Hashable {
        public let title: String
        public let url: String
        public let snippet: String

        public init(title: String, url: String, snippet: String) {
            self.title = title
            self.url = url
            self.snippet = snippet
        }
    }

    public static func searchQuery(sourceName: String) -> String {
        let label = searchSourceName(from: sourceName)
        return "\(label) API authentication documentation"
    }

    public static func inboxAPISearchQuery(sourceName: String) -> String {
        let label = searchSourceName(from: sourceName)
        return "\(label) API list conversations channels threads documentation"
    }

    public static func searchSourceName(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "this source" }
        let tokens = trimmed.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let keep = tokens.filter { token in
            token.count >= 3 && !searchStopWords.contains(token.lowercased())
        }
        if keep.isEmpty { return trimmed }
        return keep.prefix(3).joined(separator: " ")
    }

    public static func hits(fromSearchToolText text: String) -> [Hit] {
        let payload = workerJSON(fromToolText: text)
        guard let object = payload,
              let rawHits = object["hits"] as? [[String: Any]]
        else {
            return []
        }
        return rawHits.compactMap { row in
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = (row["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let snippet = (row["snippet"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty else { return nil }
            return Hit(title: title, url: url, snippet: snippet)
        }
    }

    public static func preferredDocumentationURL(fromSearchToolText text: String) -> String? {
        preferredDocumentationURL(
            from: hits(fromSearchToolText: text),
            sourceName: querySourceName(fromSearchToolText: text)
        )
    }

    public static func preferredDocumentationURL(
        from hits: [Hit],
        sourceName: String? = nil
    ) -> String? {
        let ranked: [(Int, String)] = hits.compactMap { hit in
            guard let url = sanitizedHTTPURL(hit.url) else { return nil }
            return (score(hit: hit, url: url, sourceName: sourceName), url)
        }
        return ranked.max(by: { $0.0 < $1.0 })?.1
    }

    public static func sanitizedHTTPURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil
        else {
            return nil
        }
        if host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com") {
            return nil
        }
        return url.absoluteString
    }

    private static func score(hit: Hit, url: String, sourceName: String?) -> Int {
        let blob = "\(hit.title) \(hit.snippet) \(url)".lowercased()
        var value = 1
        if blob.contains("auth") { value += 2 }
        if blob.contains("token") { value += 2 }
        if blob.contains("bot token") || blob.contains("api token") || blob.contains("bearer") {
            value += 3
        }
        if blob.contains("oauth") { value += 1 }
        if blob.contains("api") { value += 1 }
        if blob.contains("bot") { value += 1 }
        if blob.contains("docs.") { value += 2 }
        if blob.contains("/404") || blob.contains("not found") { value -= 6 }
        let ssoMarkers = [
            "sign in with", "sso", "social provider", "continue with",
            "success page", "oauth client",
        ]
        if ssoMarkers.contains(where: { blob.contains($0) }) {
            value -= 8
        }
        if let host = URL(string: url)?.host?.lowercased(),
           let source = sourceName?.lowercased(),
           !source.isEmpty {
            let tokens = source.split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .filter { $0.count >= 3 }
            if tokens.contains(where: { host.contains($0) }) {
                value += 8
            }
        }
        return value
    }

    public static func crawlSummary(fromToolText text: String) -> String? {
        let payload = workerJSON(fromToolText: text)
        if let object = payload, let pages = object["pages"] as? [[String: Any]] {
            let start = (object["start_url"] as? String)?.lowercased() ?? ""
            let usable = pages.filter { page in
                let status = page["status_code"] as? Int ?? page["statusCode"] as? Int ?? 0
                let url = (page["url"] as? String)?.lowercased() ?? ""
                if (status != 0 && (status < 200 || status >= 400)) || url.contains("/404") {
                    return false
                }
                return true
            }
            let startPages = usable.filter { page in
                let url = (page["url"] as? String)?.lowercased() ?? ""
                let depth = page["depth"] as? Int ?? 0
                if !start.isEmpty, url == start || (!start.isEmpty && url.hasPrefix(start)) {
                    return true
                }
                return depth == 0
            }
            let focused = startPages.isEmpty ? Array(usable.prefix(1)) : Array(startPages.prefix(1))
            let parts: [String] = focused.compactMap { page in
                let title = (page["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let body = (page["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let combined = [title, body].filter { !$0.isEmpty }.joined(separator: "\n")
                return combined.isEmpty ? nil : combined
            }
            let joined = parts.joined(separator: "\n\n")
            if !joined.isEmpty {
                return String(joined.prefix(2_000))
            }
        }
        guard let outcome = ToolExecutionOutcome.decode(from: text),
              let value = outcome.output?.value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(8_000))
        }
        if value.contains("\"pages\"") { return nil }
        return String(value.prefix(2_000))
    }

    private static func querySourceName(fromSearchToolText text: String) -> String? {
        guard let query = workerJSON(fromToolText: text)?["query"] as? String else {
            return nil
        }
        let name = searchSourceName(from: query)
        return name == "this source" ? nil : name
    }

    private static let searchStopWords: Set<String> = [
        "the", "a", "an", "my", "our", "that", "this", "those", "these",
        "app", "apps", "service", "vendor", "api", "inbox", "chat", "messaging",
        "tool", "tools", "work", "site", "website", "source", "place", "thing",
        "one", "from", "with", "for", "and", "or", "to", "of", "in", "on", "at",
        "already", "use", "using", "connect", "connected", "login", "account",
        "messages", "message", "channel", "channels", "bot", "send", "receive",
        "today", "please", "just",
    ]

    private static func workerJSON(fromToolText text: String) -> [String: Any]? {
        if let outcome = ToolExecutionOutcome.decode(from: text),
           let value = outcome.output?.value,
           let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}
