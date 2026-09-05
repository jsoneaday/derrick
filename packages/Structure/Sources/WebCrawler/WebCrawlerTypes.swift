import Foundation

public enum WebCrawlerLimits {
    public static let defaultMaxPages = 10
    public static let maximumMaxPages = 100
    public static let defaultMaxDepth = 2
    public static let maximumMaxDepth = 5
    public static let defaultTimeoutSeconds = 120
    public static let maximumTimeoutSeconds = 900
    public static let maximumPageBytes = 1_048_576
    public static let maximumTotalBytes = 10 * 1_048_576
    public static let maximumLinksPerPage = 200
    public static let maximumQueuedURLs = 400
    public static let maximumExtractedTextCharactersPerPage = 12_000
    public static let maximumOutputCharacters = 500_000
    public static let maximumRedirectsPerPage = 5
    public static let minimumRequestDelayMilliseconds = 150

}

public struct WebCrawlerRequest: Codable, Sendable, Hashable {
    public let startURL: String
    public let goal: String
    public let maxPages: Int
    public let maxDepth: Int
    public let timeoutSeconds: Int
    public let allowedHosts: [String]?

    public init(
        startURL: String,
        goal: String,
        maxPages: Int = WebCrawlerLimits.defaultMaxPages,
        maxDepth: Int = WebCrawlerLimits.defaultMaxDepth,
        timeoutSeconds: Int = WebCrawlerLimits.defaultTimeoutSeconds,
        allowedHosts: [String]? = nil
    ) {
        self.startURL = startURL
        self.goal = goal
        self.maxPages = maxPages
        self.maxDepth = maxDepth
        self.timeoutSeconds = timeoutSeconds
        self.allowedHosts = allowedHosts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.startURL = try container.decode(String.self, forKey: .startURL)
        self.goal = try container.decode(String.self, forKey: .goal)
        self.maxPages = try container.decodeIfPresent(Int.self, forKey: .maxPages)
            ?? WebCrawlerLimits.defaultMaxPages
        self.maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)
            ?? WebCrawlerLimits.defaultMaxDepth
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
            ?? WebCrawlerLimits.defaultTimeoutSeconds
        self.allowedHosts = try container.decodeIfPresent([String].self, forKey: .allowedHosts)
    }

    public func validated() throws -> ValidatedWebCrawlerRequest {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            throw WebCrawlerValidationError.emptyGoal
        }
        guard trimmedGoal.count <= 2_000 else {
            throw WebCrawlerValidationError.goalTooLong
        }
        if let reason = WebCrawlerSafety.maliciousGoalReason(trimmedGoal) {
            throw WebCrawlerValidationError.maliciousGoal(reason)
        }

        guard maxPages >= 1, maxPages <= WebCrawlerLimits.maximumMaxPages else {
            throw WebCrawlerValidationError.invalidMaxPages
        }
        guard maxDepth >= 0, maxDepth <= WebCrawlerLimits.maximumMaxDepth else {
            throw WebCrawlerValidationError.invalidMaxDepth
        }
        guard timeoutSeconds >= 1, timeoutSeconds <= WebCrawlerLimits.maximumTimeoutSeconds else {
            throw WebCrawlerValidationError.invalidTimeout
        }

        guard let url = URL(string: startURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil
        else {
            throw WebCrawlerValidationError.invalidStartURL
        }

        return ValidatedWebCrawlerRequest(
            startURL: WebCrawlerURL.normalize(url),
            goal: trimmedGoal,
            maxPages: maxPages,
            maxDepth: maxDepth,
            timeoutSeconds: timeoutSeconds,
            allowedHosts: resolvedAllowedHosts(startURLHost: host, explicit: allowedHosts)
        )
    }

    private func resolvedAllowedHosts(startURLHost: String, explicit: [String]?) -> Set<String> {
        var hosts = Set<String>()
        hosts.insert(startURLHost.lowercased())
        for host in explicit ?? [] {
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                hosts.insert(normalized)
            }
        }
        return hosts
    }

    enum CodingKeys: String, CodingKey {
        case startURL = "start_url"
        case goal
        case maxPages = "max_pages"
        case maxDepth = "max_depth"
        case timeoutSeconds = "timeout_seconds"
        case allowedHosts = "allowed_hosts"
    }
}

public struct ValidatedWebCrawlerRequest: Sendable, Hashable {
    public let startURL: URL
    public let goal: String
    public let maxPages: Int
    public let maxDepth: Int
    public let timeoutSeconds: Int
    public let allowedHosts: Set<String>

    public init(
        startURL: URL,
        goal: String,
        maxPages: Int,
        maxDepth: Int,
        timeoutSeconds: Int,
        allowedHosts: Set<String>
    ) {
        self.startURL = startURL
        self.goal = goal
        self.maxPages = maxPages
        self.maxDepth = maxDepth
        self.timeoutSeconds = timeoutSeconds
        self.allowedHosts = allowedHosts
    }
}

public enum WebCrawlerValidationError: Error, LocalizedError, Sendable, Equatable {
    case emptyGoal
    case goalTooLong
    case maliciousGoal(String)
    case invalidStartURL
    case invalidMaxPages
    case invalidMaxDepth
    case invalidTimeout

    public var errorDescription: String? {
        switch self {
        case .emptyGoal:
            return "A crawl goal is required."
        case .goalTooLong:
            return "The crawl goal is too long."
        case .maliciousGoal(let reason):
            return "Crawl blocked: \(reason)"
        case .invalidStartURL:
            return "start_url must be an http or https URL without embedded credentials."
        case .invalidMaxPages:
            return "max_pages must be between 1 and \(WebCrawlerLimits.maximumMaxPages)."
        case .invalidMaxDepth:
            return "max_depth must be between 0 and \(WebCrawlerLimits.maximumMaxDepth)."
        case .invalidTimeout:
            return "timeout_seconds must be between 1 and \(WebCrawlerLimits.maximumTimeoutSeconds)."
        }
    }
}

public enum WebCrawlerStopReason: String, Codable, Sendable, Hashable {
    case completed
    case maxPages = "max_pages"
    case maxDepth = "max_depth"
    case timeout
    case totalBytes = "total_bytes"
    case queueLimit = "queue_limit"
    case cancelled
    case blocked
}

public struct WebCrawlerPage: Codable, Sendable, Hashable {
    public let url: String
    public let depth: Int
    public let statusCode: Int
    public let contentType: String?
    public let title: String
    public let text: String
    public let linksFound: Int

    public init(
        url: String,
        depth: Int,
        statusCode: Int,
        contentType: String?,
        title: String,
        text: String,
        linksFound: Int
    ) {
        self.url = url
        self.depth = depth
        self.statusCode = statusCode
        self.contentType = contentType
        self.title = title
        self.text = text
        self.linksFound = linksFound
    }

    enum CodingKeys: String, CodingKey {
        case url
        case depth
        case statusCode = "status_code"
        case contentType = "content_type"
        case title
        case text
        case linksFound = "links_found"
    }
}

public struct WebCrawlerResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let startURL: String
    public let pages: [WebCrawlerPage]
    public let stopReason: WebCrawlerStopReason
    public let requestsMade: Int
    public let bytesRead: Int
    public let truncated: Bool
    public let diagnostics: [String]

    public init(
        ok: Bool,
        startURL: String,
        pages: [WebCrawlerPage],
        stopReason: WebCrawlerStopReason,
        requestsMade: Int,
        bytesRead: Int,
        truncated: Bool,
        diagnostics: [String]
    ) {
        self.ok = ok
        self.startURL = startURL
        self.pages = pages
        self.stopReason = stopReason
        self.requestsMade = requestsMade
        self.bytesRead = bytesRead
        self.truncated = truncated
        self.diagnostics = diagnostics
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case startURL = "start_url"
        case pages
        case stopReason = "stop_reason"
        case requestsMade = "requests_made"
        case bytesRead = "bytes_read"
        case truncated
        case diagnostics
    }
}

public enum WebCrawlerSafety {
    public static func maliciousGoalReason(_ goal: String) -> String? {
        let normalized = goal
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        let blockedPatterns: [(String, String)] = [
            ("ddos", "distributed denial-of-service behavior is not allowed."),
            ("denial of service", "denial-of-service behavior is not allowed."),
            ("dos attack", "denial-of-service behavior is not allowed."),
            ("flood", "flooding a website is not allowed."),
            ("hammer", "repeatedly hammering a website is not allowed."),
            ("stress test", "load or stress testing a third-party website is not allowed."),
            ("load test", "load or stress testing a third-party website is not allowed."),
            ("port scan", "port scanning is not a web crawl."),
            ("brute force", "brute-force activity is not allowed."),
            ("infinite loop", "unbounded or infinite crawling is not allowed."),
            ("loop forever", "unbounded or infinite crawling is not allowed."),
            ("crawl forever", "unbounded or infinite crawling is not allowed."),
            ("never stop crawling", "unbounded or infinite crawling is not allowed."),
            ("unbounded crawl", "unbounded or infinite crawling is not allowed.")
        ]
        return blockedPatterns.first { normalized.contains($0.0) }?.1
    }

}
public enum WebCrawlerURL {
    public static func isHTTP(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    public static func normalize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if let port = components.port,
           (components.scheme == "http" && port == 80)
               || (components.scheme == "https" && port == 443) {
            components.port = nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url ?? url
    }

    public static func key(_ url: URL) -> String {
        normalize(url).absoluteString
    }

    private static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }
}
