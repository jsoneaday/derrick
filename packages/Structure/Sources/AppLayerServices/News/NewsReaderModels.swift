import Foundation

public enum NewsReaderMode: String, Codable, Sendable, Hashable, CaseIterable {
    case rss
    case list
    case summary

    public var displayName: String {
        switch self {
        case .rss: return "RSS feed"
        case .list: return "Crawl site"
        case .summary: return "AI summary"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "rss": self = .rss
        case "list": self = .list
        case "summary", "summaries": self = .summary
        default:
            self = .rss
        }
    }
}

public enum NewsReaderSchedule: String, Codable, Sendable, Hashable, CaseIterable {
    case off
    case hourly
    case daily

    public var displayName: String {
        switch self {
        case .off: return "Only when opened"
        case .hourly: return "Every hour"
        case .daily: return "Every day"
        }
    }
}

public struct NewsSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var url: String

    public init(id: String = UUID().uuidString, label: String, url: String) {
        self.id = id
        self.label = label
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct NewsReaderSpec: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var topics: [String]
    public var sources: [NewsSource]
    public var mode: NewsReaderMode
    public var maxCount: Int
    public var schedule: NewsReaderSchedule
    public var summaryText: String?
    public var lastError: String?
    public var lastFetchedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        topics: [String],
        sources: [NewsSource],
        mode: NewsReaderMode = .rss,
        maxCount: Int = 20,
        schedule: NewsReaderSchedule = .off,
        summaryText: String? = nil,
        lastError: String? = nil,
        lastFetchedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.topics = topics.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.sources = sources.filter { !$0.url.isEmpty }
        self.mode = mode
        self.maxCount = min(50, max(1, maxCount))
        self.schedule = schedule
        self.summaryText = summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.lastError = lastError
        self.lastFetchedAt = lastFetchedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NewsItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var readerID: String
    public var title: String
    public var sourceURL: String
    public var sourceLabel: String
    public var summary: String?
    public var publishedAt: Date?
    public var fetchedAt: Date

    public init(
        id: String = UUID().uuidString,
        readerID: String,
        title: String,
        sourceURL: String,
        sourceLabel: String,
        summary: String? = nil,
        publishedAt: Date? = nil,
        fetchedAt: Date = .now
    ) {
        self.id = id
        self.readerID = readerID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceLabel = sourceLabel
        self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
    }
}

public enum NewsPresetTopic: String, Sendable, CaseIterable, Identifiable {
    case financial
    case tech
    case international
    case politics
    case science
    case sports

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .financial: return "Financial"
        case .tech: return "Tech"
        case .international: return "International"
        case .politics: return "Politics"
        case .science: return "Science"
        case .sports: return "Sports"
        }
    }
}

public enum NewsPresetSource: String, Sendable, CaseIterable, Identifiable {
    case googleNews
    case foxNews
    case newsmax
    case nationalReview
    case wsj

    public var id: String { rawValue }

    public var source: NewsSource {
        switch self {
        case .googleNews:
            return NewsSource(
                id: rawValue,
                label: "Google News",
                url: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en"
            )
        case .foxNews:
            return NewsSource(
                id: rawValue,
                label: "Fox News",
                url: "https://moxie.foxnews.com/google-publisher/latest.xml"
            )
        case .newsmax:
            return NewsSource(
                id: rawValue,
                label: "Newsmax",
                url: "https://www.newsmax.com/rss/Newsfront/"
            )
        case .nationalReview:
            return NewsSource(
                id: rawValue,
                label: "National Review",
                url: "https://www.nationalreview.com/feed/"
            )
        case .wsj:
            return NewsSource(
                id: rawValue,
                label: "Wall Street Journal",
                url: "https://feeds.a.dj.com/rss/RSSWorldNews.xml"
            )
        }
    }
}

public enum NewsReaderError: Error, Sendable, Equatable, LocalizedError {
    case paywalled(url: String, detail: String)
    case invalidURL(String)
    case emptySources
    case emptyName
    case fetchFailed(url: String, detail: String)
    case notReady
    case summarizerUnavailable
    case workerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .paywalled(let url, let detail):
            return "This source is behind a paywall, which is not supported yet. \(detail) (\(url))"
        case .invalidURL(let url):
            return "That is not a usable web address: \(url)"
        case .emptySources:
            return "Add at least one source or URL."
        case .emptyName:
            return "Give this news list a name."
        case .fetchFailed(let url, let detail):
            return "Could not read \(url). \(detail)"
        case .notReady:
            return "News lists are not ready yet. Try again in a moment."
        case .summarizerUnavailable:
            return "Add an API key in Settings before creating an AI summary list."
        case .workerUnavailable(let detail):
            return "News reader worker is not available. \(detail)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
