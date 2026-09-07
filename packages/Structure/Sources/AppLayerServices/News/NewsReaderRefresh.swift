import Foundation

public protocol NewsHTTPClient: Sendable {
    func get(url: URL) async throws -> NewsHTTPResponse
}

public struct NewsHTTPResponse: Sendable {
    public var status: Int
    public var contentType: String?
    public var body: Data

    public init(status: Int, contentType: String?, body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }
}

public struct URLSessionNewsHTTPClient: NewsHTTPClient {
    public init() {}

    public func get(url: URL) async throws -> NewsHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return NewsHTTPResponse(
            status: http?.statusCode ?? 0,
            contentType: http?.value(forHTTPHeaderField: "Content-Type"),
            body: data
        )
    }
}

public enum NewsReaderRefresh {
    public static func validateAndFetch(
        spec: NewsReaderSpec,
        client: any NewsHTTPClient
    ) async throws -> [NewsItem] {
        let name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NewsReaderError.emptyName }
        guard !spec.sources.isEmpty else { throw NewsReaderError.emptySources }

        var collected: [NewsItem] = []
        for source in spec.sources {
            let parsed = try await fetchSource(source, readerID: spec.id, client: client)
            collected.append(contentsOf: parsed)
        }

        let filtered = filter(collected, topics: spec.topics)
        let unique = uniqued(filtered)
        let sorted = unique.sorted { lhs, rhs in
            (lhs.publishedAt ?? lhs.fetchedAt) > (rhs.publishedAt ?? rhs.fetchedAt)
        }
        return Array(sorted.prefix(spec.maxCount))
    }

    public static func digest(from items: [NewsItem]) -> String {
        let lines = items.prefix(8).map { item in
            "• \(item.title) (\(item.sourceLabel))"
        }
        return lines.joined(separator: "\n")
    }

    private static func fetchSource(
        _ source: NewsSource,
        readerID: String,
        client: any NewsHTTPClient
    ) async throws -> [NewsItem] {
        guard let url = URL(string: source.url), url.scheme == "http" || url.scheme == "https" else {
            throw NewsReaderError.invalidURL(source.url)
        }
        let fetchURL = NewsSourceURL.canonicalFetchURL(url)
        if let reason = NewsPaywall.preflightRejection(url: fetchURL) {
            throw NewsReaderError.paywalled(url: source.url, detail: reason)
        }
        let response: NewsHTTPResponse
        do {
            response = try await client.get(url: fetchURL)
        } catch {
            throw NewsReaderError.fetchFailed(url: source.url, detail: error.localizedDescription)
        }
        if let reason = NewsPaywall.rejectionReason(
            url: fetchURL,
            status: response.status,
            contentType: response.contentType,
            body: response.body
        ) {
            throw NewsReaderError.paywalled(url: source.url, detail: reason)
        }
        if response.status != 0, response.status < 200 || response.status >= 400 {
            throw NewsReaderError.fetchFailed(url: source.url, detail: "HTTP \(response.status)")
        }
        let entries = NewsFeedParser.parse(data: response.body, sourceLabel: source.label, fallbackPageURL: fetchURL)
        guard !entries.isEmpty else {
            throw NewsReaderError.fetchFailed(
                url: source.url,
                detail: "No articles were found. For Google News, Derrick uses the public RSS feed."
            )
        }
        return entries.map { entry in
            NewsItem(
                readerID: readerID,
                title: entry.title,
                sourceURL: entry.sourceURL,
                sourceLabel: source.label,
                summary: entry.summary,
                publishedAt: entry.publishedAt
            )
        }
    }

    private static func filter(_ items: [NewsItem], topics: [String]) -> [NewsItem] {
        let needles = topics.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return items }
        let matched = items.filter { item in
            let hay = "\(item.title) \(item.summary ?? "")".lowercased()
            return needles.contains { hay.contains($0) }
        }
        return matched.isEmpty ? items : matched
    }

    private static func uniqued(_ items: [NewsItem]) -> [NewsItem] {
        var seen = Set<String>()
        var result: [NewsItem] = []
        for item in items {
            if seen.insert(item.sourceURL).inserted {
                result.append(item)
            }
        }
        return result
    }
}
