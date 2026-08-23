import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Selenops
import SwiftSoup

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

    public init(
        startURL: String,
        goal: String,
        maxPages: Int = WebCrawlerLimits.defaultMaxPages,
        maxDepth: Int = WebCrawlerLimits.defaultMaxDepth,
        timeoutSeconds: Int = WebCrawlerLimits.defaultTimeoutSeconds
    ) {
        self.startURL = startURL
        self.goal = goal
        self.maxPages = maxPages
        self.maxDepth = maxDepth
        self.timeoutSeconds = timeoutSeconds
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
            timeoutSeconds: timeoutSeconds
        )
    }

    enum CodingKeys: String, CodingKey {
        case startURL = "start_url"
        case goal
        case maxPages = "max_pages"
        case maxDepth = "max_depth"
        case timeoutSeconds = "timeout_seconds"
    }
}

public struct ValidatedWebCrawlerRequest: Sendable, Hashable {
    public let startURL: URL
    public let goal: String
    public let maxPages: Int
    public let maxDepth: Int
    public let timeoutSeconds: Int

    public init(
        startURL: URL,
        goal: String,
        maxPages: Int,
        maxDepth: Int,
        timeoutSeconds: Int
    ) {
        self.startURL = startURL
        self.goal = goal
        self.maxPages = maxPages
        self.maxDepth = maxDepth
        self.timeoutSeconds = timeoutSeconds
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

public enum WebCrawlerEngine {
    public static func run(
        request: WebCrawlerRequest,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        proxyToken: String? = nil
    ) async -> WebCrawlerResult {
        do {
            let validated = try request.validated()
            return try await run(
                request: validated,
                proxyHost: proxyHost,
                proxyPort: proxyPort,
                proxyToken: proxyToken
            )
        } catch {
            return WebCrawlerResult(
                ok: false,
                startURL: request.startURL,
                pages: [],
                stopReason: .blocked,
                requestsMade: 0,
                bytesRead: 0,
                truncated: false,
                diagnostics: [error.localizedDescription]
            )
        }
    }

    public static func run(
        request: ValidatedWebCrawlerRequest,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        proxyToken: String? = nil
    ) async throws -> WebCrawlerResult {
        let fetcher = try AsyncHTTPFetcher(
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            proxyToken: proxyToken
        )
        let delegate = WebCrawlerDelegate(request: request, fetcher: fetcher)
        let crawler = Crawler(delegate: delegate)

        let result: WebCrawlerResult
        do {
            result = try await withThrowingTaskGroup(of: WebCrawlerResult.self) { group in
                group.addTask {
                    await crawler.start(url: request.startURL)
                    return await delegate.result()
                }
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64(request.timeoutSeconds) * 1_000_000_000
                    )
                    throw WebCrawlerRuntimeError.timedOut
                }
                guard let result = try await group.next() else {
                    throw WebCrawlerRuntimeError.timedOut
                }
                group.cancelAll()
                _ = try? await group.next()
                return result
            }
        } catch WebCrawlerRuntimeError.timedOut {
            await delegate.stop(reason: .timeout)
            result = await delegate.result()
        } catch is CancellationError {
            await delegate.stop(reason: .cancelled)
            result = await delegate.result()
        }
        try? await fetcher.shutdown()
        return result
    }
}

private enum WebCrawlerRuntimeError: Error, LocalizedError, Sendable {
    case timedOut
    case invalidProxy
    case redirectOutOfScope
    case redirectLoop
    case redirectLimit

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "crawl timeout reached"
        case .invalidProxy:
            return "invalid egress proxy configuration"
        case .redirectOutOfScope:
            return "redirect left the start URL origin"
        case .redirectLoop:
            return "redirect loop detected"
        case .redirectLimit:
            return "redirect limit reached"
        }
    }
}

private struct FetchedPage: Sendable {
    let url: URL
    let statusCode: Int
    let contentType: String?
    let body: String
}

private actor AsyncHTTPFetcher {
    private let client: HTTPClient
    private let proxyHost: String?
    private let proxyPort: Int?
    private let proxyToken: String?
    private var lastRequestAt: Date?

    init(proxyHost: String?, proxyPort: Int?, proxyToken: String?) throws {
        if proxyHost != nil && (proxyPort == nil || proxyToken == nil)
            || proxyHost == nil && (proxyPort != nil || proxyToken != nil) {
            throw WebCrawlerRuntimeError.invalidProxy
        }
        if let proxyPort, !(1...65_535).contains(proxyPort) {
            throw WebCrawlerRuntimeError.invalidProxy
        }

        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        if let proxyHost, let proxyPort, let proxyToken {
            var connectHeaders = HTTPHeaders()
            connectHeaders.add(name: "X-Derrick-Crawler-Token", value: proxyToken)
            configuration.proxy = .server(
                host: proxyHost,
                port: proxyPort,
                connectHeaders: connectHeaders
            )
        }
        client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: configuration
        )
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyToken = proxyToken
    }

    func fetch(
        _ url: URL,
        maxBytes: Int
    ) async throws -> FetchedPage {
        try await waitForRequestSpacing()

        var currentURL = url
        var redirectedURLs = Set([WebCrawlerURL.key(url)])

        for _ in 0...WebCrawlerLimits.maximumRedirectsPerPage {
            var request = HTTPClientRequest(url: currentURL.absoluteString)
            request.method = .GET
            request.headers.add(name: "User-Agent", value: "DerrickWebCrawler/1")
            request.headers.add(name: "Accept", value: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
            request.headers.add(name: "Accept-Language", value: "en-US,en;q=0.9")
            request.headers.add(name: "Accept-Encoding", value: "identity")

            let response = try await client.execute(
                request,
                timeout: .seconds(20)
            )
            let bodyBuffer = try await response.body.collect(upTo: maxBytes)
            let bodyBytes = bodyBuffer.getBytes(
                at: bodyBuffer.readerIndex,
                length: bodyBuffer.readableBytes
            ) ?? []
            let body = String(decoding: bodyBytes, as: UTF8.self)

            guard response.status.code >= 300, response.status.code < 400 else {
                return FetchedPage(
                    url: currentURL,
                    statusCode: Int(response.status.code),
                    contentType: response.headers.first(name: "content-type"),
                    body: body
                )
            }

            guard let location = response.headers.first(name: "location"),
                  let redirectURL = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                  WebCrawlerURL.isHTTP(redirectURL),
                  WebCrawlerURL.isSameOrigin(currentURL, redirectURL)
            else {
                throw WebCrawlerRuntimeError.redirectOutOfScope
            }

            let normalizedRedirect = WebCrawlerURL.normalize(redirectURL)
            guard redirectedURLs.insert(WebCrawlerURL.key(normalizedRedirect)).inserted else {
                throw WebCrawlerRuntimeError.redirectLoop
            }
            currentURL = normalizedRedirect
            try await waitForRequestSpacing()
        }

        throw WebCrawlerRuntimeError.redirectLimit
    }

    func shutdown() throws {
        try client.syncShutdown()
    }

    private func waitForRequestSpacing() async throws {
        let now = Date()
        if let lastRequestAt {
            let elapsed = now.timeIntervalSince(lastRequestAt)
            let minimum = TimeInterval(WebCrawlerLimits.minimumRequestDelayMilliseconds) / 1_000
            if elapsed < minimum {
                let wait = minimum - elapsed
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }
}

private actor WebCrawlerDelegate: CrawlerDelegate {
    private let request: ValidatedWebCrawlerRequest
    private let fetcher: AsyncHTTPFetcher
    private let startHost: String
    private let deadline: Date

    private var queue: [(url: URL, depth: Int)] = []
    private var queuedKeys = Set<String>()
    private var visitedKeys = Set<String>()
    private var pageDepths: [String: Int] = [:]
    private var pages: [WebCrawlerPage] = []
    private var pageIndexes: [String: Int] = [:]
    private var diagnostics: [String] = []
    private var stopReason: WebCrawlerStopReason?
    private var reachedMaxDepth = false
    private var requestsMade = 0
    private var bytesRead = 0

    init(request: ValidatedWebCrawlerRequest, fetcher: AsyncHTTPFetcher) {
        self.request = request
        self.fetcher = fetcher
        self.startHost = request.startURL.host?.lowercased() ?? ""
        self.deadline = Date().addingTimeInterval(TimeInterval(request.timeoutSeconds))
    }

    func crawler(_ crawler: Crawler, shouldVisitUrl url: URL) async -> Crawler.Decision {
        guard !Task.isCancelled else {
            stopReason = .cancelled
            return .skip(.businessLogic("crawl cancelled"))
        }
        guard stopReason == nil else {
            return .skip(.businessLogic("crawl stopped"))
        }
        guard Date() < deadline else {
            stopReason = .timeout
            return .skip(.businessLogic("crawl timeout reached"))
        }
        guard WebCrawlerURL.isHTTP(url) else {
            return .skip(.invalidURL)
        }

        let normalized = WebCrawlerURL.normalize(url)
        let key = WebCrawlerURL.key(normalized)
        guard normalized.host?.lowercased() == startHost else {
            return .skip(.businessLogic("different origin"))
        }
        guard visitedKeys.insert(key).inserted else {
            return .skip(.businessLogic("URL already visited"))
        }
        guard visitedKeys.count <= request.maxPages else {
            stopReason = .maxPages
            return .skip(.businessLogic("maximum page limit reached"))
        }

        pageDepths[key] = pageDepths[key] ?? 0
        return .visit
    }

    func crawler(_ crawler: Crawler, willVisitUrl url: URL) async {
        _ = crawler
        _ = url
    }

    func crawler(_ crawler: Crawler, visit url: URL) async throws {
        guard stopReason == nil else { return }
        guard Date() < deadline else {
            stopReason = .timeout
            return
        }

        let normalized = WebCrawlerURL.normalize(url)
        let key = WebCrawlerURL.key(normalized)
        let depth = pageDepths[key] ?? 0
        requestsMade += 1

        do {
            let fetched = try await fetcher.fetch(
                normalized,
                maxBytes: WebCrawlerLimits.maximumPageBytes
            )
            bytesRead += fetched.body.utf8.count
            if bytesRead > WebCrawlerLimits.maximumTotalBytes {
                stopReason = .totalBytes
                return
            }

            let extracted = extract(fetched.body, contentType: fetched.contentType, baseURL: fetched.url)
            pages.append(
                WebCrawlerPage(
                    url: fetched.url.absoluteString,
                    depth: depth,
                    statusCode: fetched.statusCode,
                    contentType: fetched.contentType,
                    title: extracted.title,
                    text: extracted.text,
                    linksFound: 0
                )
            )
            let pageIndex = pages.count - 1
            pageIndexes[key] = pageIndex
            let fetchedKey = WebCrawlerURL.key(fetched.url)
            pageIndexes[fetchedKey] = pageIndex
            pageDepths[fetchedKey] = depth

            guard extracted.isHTML else { return }
            await crawler.parseLinks(from: fetched.body, at: fetched.url)
        } catch {
            diagnostics.append("\(normalized.absoluteString): \(error.localizedDescription)")
        }
    }

    func crawler(_ crawler: Crawler, didVisit url: URL) async {
        _ = crawler
        _ = url
    }

    func crawler(
        _ crawler: Crawler,
        didFindLinks links: Set<Crawler.Link>,
        at url: URL
    ) async {
        _ = crawler
        let sourceKey = WebCrawlerURL.key(WebCrawlerURL.normalize(url))
        let sortedLinks = links.sorted {
            WebCrawlerURL.key(WebCrawlerURL.normalize($0.url))
                < WebCrawlerURL.key(WebCrawlerURL.normalize($1.url))
        }
        let limitedLinks = sortedLinks.prefix(WebCrawlerLimits.maximumLinksPerPage)
        var acceptedLinks = 0

        for link in limitedLinks {
            guard stopReason == nil else { break }
            let normalized = WebCrawlerURL.normalize(link.url)
            let key = WebCrawlerURL.key(normalized)
            guard normalized.host?.lowercased() == startHost,
                  WebCrawlerURL.isHTTP(normalized),
                  !visitedKeys.contains(key),
                  queuedKeys.insert(key).inserted
            else {
                continue
            }

            let sourceDepth = pageDepths[sourceKey] ?? 0
            let nextDepth = sourceDepth + 1
            guard nextDepth <= request.maxDepth else {
                reachedMaxDepth = true
                queuedKeys.remove(key)
                continue
            }
            guard queue.count < WebCrawlerLimits.maximumQueuedURLs else {
                stopReason = .queueLimit
                queuedKeys.remove(key)
                break
            }
            pageDepths[key] = nextDepth
            queue.append((normalized, nextDepth))
            acceptedLinks += 1
        }

        if let pageIndex = pageIndexes[sourceKey] {
            pages[pageIndex] = WebCrawlerPage(
                url: pages[pageIndex].url,
                depth: pages[pageIndex].depth,
                statusCode: pages[pageIndex].statusCode,
                contentType: pages[pageIndex].contentType,
                title: pages[pageIndex].title,
                text: pages[pageIndex].text,
                linksFound: acceptedLinks
            )
        }
    }

    func crawler(
        _ crawler: Crawler,
        didSkip url: URL,
        reason: Crawler.SkipReason
    ) async {
        _ = crawler
        let message = String(describing: reason)
        if !message.contains("already visited"),
           !message.contains("different origin"),
           !message.contains("crawl stopped") {
            diagnostics.append("\(WebCrawlerURL.normalize(url).absoluteString): skipped (\(message))")
        }
    }

    func crawler(_ crawler: Crawler) async -> URL? {
        _ = crawler
        guard stopReason == nil else { return nil }
        guard !Task.isCancelled else {
            stopReason = .cancelled
            return nil
        }
        guard Date() < deadline else {
            stopReason = .timeout
            return nil
        }
        guard pages.count < request.maxPages else {
            stopReason = .maxPages
            return nil
        }
        guard !queue.isEmpty else { return nil }

        let next = queue.removeFirst()
        queuedKeys.remove(WebCrawlerURL.key(next.url))
        return next.url
    }

    func crawlerDidFinish(_ crawler: Crawler) async {
        _ = crawler
        if stopReason == nil {
            stopReason = reachedMaxDepth ? .maxDepth : .completed
        }
    }

    func stop(reason: WebCrawlerStopReason) {
        stopReason = reason
    }

    func result() -> WebCrawlerResult {
        let reason = stopReason ?? .completed
        var outputPages: [WebCrawlerPage] = []
        var outputCharacters = 0
        var outputTruncated = false

        for page in pages {
            guard outputCharacters < WebCrawlerLimits.maximumOutputCharacters else {
                outputTruncated = true
                break
            }
            let remaining = WebCrawlerLimits.maximumOutputCharacters - outputCharacters
            let text = String(page.text.prefix(remaining))
            if text.count < page.text.count {
                outputTruncated = true
            }
            outputPages.append(
                WebCrawlerPage(
                    url: page.url,
                    depth: page.depth,
                    statusCode: page.statusCode,
                    contentType: page.contentType,
                    title: page.title,
                    text: text,
                    linksFound: page.linksFound
                )
            )
            outputCharacters += text.count
        }

        var resultDiagnostics = diagnostics
        if outputTruncated {
            resultDiagnostics.append("Output was truncated at \(WebCrawlerLimits.maximumOutputCharacters) characters.")
        }
        if reason == .maxDepth {
            resultDiagnostics.append("Some links were not visited because max_depth was reached.")
        }

        return WebCrawlerResult(
            ok: reason != .blocked && !outputPages.isEmpty,
            startURL: request.startURL.absoluteString,
            pages: outputPages,
            stopReason: reason,
            requestsMade: requestsMade,
            bytesRead: bytesRead,
            truncated: outputTruncated,
            diagnostics: resultDiagnostics
        )
    }

    private func extract(
        _ html: String,
        contentType: String?,
        baseURL: URL
    ) -> (title: String, text: String, isHTML: Bool) {
        let isHTML = contentType?.lowercased().contains("html") == true
            || html.range(of: "<html", options: .caseInsensitive) != nil
        guard isHTML else {
            return (
                title: "",
                text: String(html.prefix(WebCrawlerLimits.maximumExtractedTextCharactersPerPage)),
                isHTML: false
            )
        }

        do {
            let document = try SwiftSoup.parse(html, baseURL.absoluteString)
            let title = (try? document.title())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            for element in try document.select("script,style,noscript,template,svg").array() {
                try element.remove()
            }
            let rawText = try document.body()?.text() ?? document.text()
            let normalizedText = rawText
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return (
                title: String(title.prefix(500)),
                text: String(normalizedText.prefix(WebCrawlerLimits.maximumExtractedTextCharactersPerPage)),
                isHTML: true
            )
        } catch {
            return (
                title: "",
                text: String(html.prefix(WebCrawlerLimits.maximumExtractedTextCharactersPerPage)),
                isHTML: true
            )
        }
    }
}

private enum WebCrawlerURL {
    static func isHTTP(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    static func normalize(_ url: URL) -> URL {
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

    static func key(_ url: URL) -> String {
        normalize(url).absoluteString
    }

    private static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }
}
