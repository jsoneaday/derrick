import Foundation

/// Host-side paywall policy for news URLs. RSS/Atom feeds can still be used
/// from a paywalled publisher; HTML article pages on known paywall hosts fail.
public enum NewsPaywall {
    public static let userWarning =
        "URLs with paywalls are not supported yet. Use a public RSS or Atom feed, or an open page. Paid article URLs will fail."

    public static let knownHosts: Set<String> = [
        "nytimes.com",
        "www.nytimes.com",
        "wsj.com",
        "www.wsj.com",
        "ft.com",
        "www.ft.com",
        "economist.com",
        "www.economist.com",
        "bloomberg.com",
        "www.bloomberg.com",
        "washingtonpost.com",
        "www.washingtonpost.com",
        "newyorker.com",
        "www.newyorker.com",
        "theathletic.com",
        "www.theathletic.com",
        "barrons.com",
        "www.barrons.com",
        "seekingalpha.com",
        "www.seekingalpha.com",
        "theinformation.com",
        "www.theinformation.com",
    ]

    public static func hostLooksPaywalled(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        if knownHosts.contains(host) { return true }
        return knownHosts.contains { host.hasSuffix(".\($0)") || host == $0 }
    }

    /// RSS/Atom endpoints are allowed even when the publisher paywalls HTML articles.
    public static func looksLikePublicFeedURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let host = (url.host ?? "").lowercased()
        if path.contains("rss") || path.contains("atom") || path.contains("/feed") { return true }
        if path.hasSuffix(".xml") { return true }
        if host.hasPrefix("rss.") || host.hasPrefix("feeds.") { return true }
        return false
    }

    /// Fail known paywalled article pages before a fetch. Feed URLs on those hosts pass.
    public static func preflightRejection(url: URL) -> String? {
        if looksLikePublicFeedURL(url) { return nil }
        if hostLooksPaywalled(url) {
            return "This publisher’s article pages are paywalled. Use their public RSS feed instead."
        }
        return nil
    }

    public static func isFeedContentType(_ contentType: String?) -> Bool {
        let value = (contentType ?? "").lowercased()
        return value.contains("rss")
            || value.contains("atom")
            || value.contains("xml")
            || value.contains("json")
    }

    public static func htmlLooksPaywalled(_ html: String) -> Bool {
        let lower = html.lowercased()
        let markers = [
            "paywall",
            "subscribe to continue",
            "subscription to read",
            "create a free account to continue",
            "piano-paywall",
            "tp-container-inner",
            "regwall",
            "metered_paywall",
            "subscribers only",
            "this article is for subscribers",
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Returns a user-facing reason when this response must not be used as a news source.
    public static func rejectionReason(
        url: URL,
        status: Int,
        contentType: String?,
        body: Data
    ) -> String? {
        if status == 401 || status == 402 || status == 403 {
            return "The site asked for a login or payment (HTTP \(status))."
        }
        if isFeedContentType(contentType) {
            return nil
        }
        let text = String(data: body, encoding: .utf8)
            ?? String(data: body, encoding: .isoLatin1)
            ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") || trimmed.lowercased().hasPrefix("<!doctype") {
            if htmlLooksPaywalled(text) {
                return "The page is a paywalled article."
            }
            if hostLooksPaywalled(url) {
                return "This publisher’s article pages are paywalled. Use their public RSS feed instead."
            }
        }
        if hostLooksPaywalled(url), !isFeedContentType(contentType), !looksLikeFeed(text) {
            return "This publisher’s article pages are paywalled. Use their public RSS feed instead."
        }
        return nil
    }

    public static func looksLikeFeed(_ text: String) -> Bool {
        let prefix = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)).lowercased()
        return prefix.contains("<rss")
            || prefix.contains("<feed")
            || prefix.contains("<rdf:rdf")
    }
}
