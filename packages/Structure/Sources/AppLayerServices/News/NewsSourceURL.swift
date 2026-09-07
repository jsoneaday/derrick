import Foundation

/// Rewrites well-known news homepages to a public RSS/Atom endpoint the host can parse.
public enum NewsSourceURL {
    public static func canonicalFetchURL(_ url: URL) -> URL {
        let host = (url.host ?? "").lowercased()
        guard isGoogleNewsHost(host) else { return url }
        let path = url.path.lowercased()
        if path.contains("/rss") || path.hasSuffix(".xml") {
            return url
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.scheme = "https"
        parts.host = "news.google.com"
        parts.path = "/rss"
        if parts.queryItems == nil || parts.queryItems?.isEmpty == true {
            parts.queryItems = [
                URLQueryItem(name: "hl", value: "en-US"),
                URLQueryItem(name: "gl", value: "US"),
                URLQueryItem(name: "ceid", value: "US:en"),
            ]
        }
        parts.fragment = nil
        return parts.url ?? URL(string: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en")!
    }

    public static func isGoogleNewsHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "news.google.com" || value.hasSuffix(".news.google.com")
    }
}
