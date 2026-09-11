import Foundation

public enum NewsReaderRefresh {
    public static func validateAndFetch(
        spec: NewsReaderSpec,
        worker: any NewsWorkerRunning,
        summarizer: NewsSummaryGenerating? = nil
    ) async throws -> NewsReaderFetchResult {
        let name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NewsReaderError.emptyName }
        guard !spec.sources.isEmpty else { throw NewsReaderError.emptySources }

        for source in spec.sources {
            guard let url = URL(string: source.url), url.scheme == "http" || url.scheme == "https" else {
                throw NewsReaderError.invalidURL(source.url)
            }
            if let reason = NewsPaywall.preflightRejection(url: url) {
                throw NewsReaderError.paywalled(url: source.url, detail: reason)
            }
        }

        let request = NewsReaderWorkerRequest(
            mode: spec.mode,
            sources: spec.sources,
            topics: spec.topics,
            maxCount: spec.maxCount,
            contextHint: ([spec.name] + spec.topics).joined(separator: " ")
        )
        let requestJSON = try request.encodedJSON()
        let stdout = try await worker.run(requestJSON: requestJSON)
        let result = try JSONDecoder.service.decode(NewsReaderWorkerResult.self, from: stdout)
        guard result.ok else {
            let detail = result.diagnostics.joined(separator: " ")
            throw NewsReaderError.fetchFailed(
                url: spec.sources.first?.url ?? name,
                detail: detail.isEmpty ? "News reader returned no articles." : detail
            )
        }

        let items = result.articles.map { article in
            NewsItem(
                readerID: spec.id,
                title: article.title,
                sourceURL: article.url,
                sourceLabel: sourceLabel(for: article.url, sources: spec.sources),
                summary: article.detail?.nilIfEmpty,
                publishedAt: parsePublishedAt(article.publishedAt)
            )
        }

        var summaryText: String?
        if spec.mode == .summary {
            guard let summarizer else {
                throw NewsReaderError.summarizerUnavailable
            }
            summaryText = try await summarizer.summarize(
                listName: spec.name,
                topics: spec.topics,
                articles: items
            )
        }

        return NewsReaderFetchResult(items: items, summaryText: summaryText)
    }

    private static func sourceLabel(for url: String, sources: [NewsSource]) -> String {
        if let host = URL(string: url)?.host {
            if let match = sources.first(where: { URL(string: $0.url)?.host == host }) {
                return match.label
            }
            return host
        }
        return sources.first?.label ?? "Source"
    }

    private static func parsePublishedAt(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = rfc.date(from: raw) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}

public struct NewsReaderFetchResult: Sendable, Hashable {
    public var items: [NewsItem]
    public var summaryText: String?

    public init(items: [NewsItem], summaryText: String? = nil) {
        self.items = items
        self.summaryText = summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public protocol NewsSummaryGenerating: Sendable {
    func summarize(listName: String, topics: [String], articles: [NewsItem]) async throws -> String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
