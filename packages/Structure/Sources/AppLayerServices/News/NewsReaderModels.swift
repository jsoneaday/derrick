import Foundation

public enum NewsReaderMode: String, Codable, Sendable, Hashable, CaseIterable {
    case list
    case summaries

    public var displayName: String {
        switch self {
        case .list: return "List articles"
        case .summaries: return "Summaries"
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
    public var lastError: String?
    public var lastFetchedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        topics: [String],
        sources: [NewsSource],
        mode: NewsReaderMode = .list,
        maxCount: Int = 20,
        schedule: NewsReaderSchedule = .off,
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
    case bbcWorld
    case npr
    case bbcTech
    case hn
    case googleNews

    public var id: String { rawValue }

    public var source: NewsSource {
        switch self {
        case .bbcWorld:
            return NewsSource(id: rawValue, label: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml")
        case .npr:
            return NewsSource(id: rawValue, label: "NPR", url: "https://feeds.npr.org/1001/rss.xml")
        case .bbcTech:
            return NewsSource(id: rawValue, label: "BBC Technology", url: "https://feeds.bbci.co.uk/news/technology/rss.xml")
        case .hn:
            return NewsSource(id: rawValue, label: "Hacker News", url: "https://hnrss.org/frontpage")
        case .googleNews:
            return NewsSource(
                id: rawValue,
                label: "Google News",
                url: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en"
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
        }
    }
}
