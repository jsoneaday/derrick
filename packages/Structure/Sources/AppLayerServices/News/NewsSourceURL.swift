import Foundation

/// Rewrites well-known news homepages to a public RSS/Atom endpoint the host can parse.
public enum NewsSourceURL {
    /// Rewrites Google News HTML/topic URLs to RSS feeds the host can fetch reliably.
    /// `contextHint` may carry a crawl goal or user prompt (for example "tech news").
    public static func canonicalFetchURL(_ url: URL, contextHint: String? = nil) -> URL {
        let host = (url.host ?? "").lowercased()
        guard isGoogleNewsHost(host) else { return url }
        let path = url.path.lowercased()
        if path.contains("/rss") || path.hasSuffix(".xml") {
            return url
        }
        if path.contains("/topics/") {
            if let section = googleNewsSection(from: contextHint) {
                return googleNewsSectionRSS(section: section)
            }
            return googleNewsGeneralRSS()
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.scheme = "https"
        parts.host = "news.google.com"
        parts.path = "/rss"
        if parts.queryItems == nil || parts.queryItems?.isEmpty == true {
            parts.queryItems = defaultLocaleQueryItems
        }
        parts.fragment = nil
        return parts.url ?? googleNewsGeneralRSS()
    }

    public static func isGoogleNewsHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "news.google.com" || value.hasSuffix(".news.google.com")
    }

    private static let defaultLocaleQueryItems = [
        URLQueryItem(name: "hl", value: "en-US"),
        URLQueryItem(name: "gl", value: "US"),
        URLQueryItem(name: "ceid", value: "US:en"),
    ]

    private static func googleNewsGeneralRSS() -> URL {
        URL(string: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en")!
    }

    private static func googleNewsSectionRSS(section: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "news.google.com"
        parts.path = "/rss/headlines/section/topic/\(section)"
        parts.queryItems = defaultLocaleQueryItems
        return parts.url ?? googleNewsGeneralRSS()
    }

    private static func googleNewsSection(from contextHint: String?) -> String? {
        let hint = (contextHint ?? "")
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        if hint.contains("tech") {
            return "TECHNOLOGY"
        }
        if hint.contains("business") || hint.contains("finance") || hint.contains("market") {
            return "BUSINESS"
        }
        if hint.contains("science") {
            return "SCIENCE"
        }
        if hint.contains("sport") {
            return "SPORTS"
        }
        if hint.contains("health") {
            return "HEALTH"
        }
        if hint.contains("entertainment") {
            return "ENTERTAINMENT"
        }
        if hint.contains("world") {
            return "WORLD"
        }
        return nil
    }
}
