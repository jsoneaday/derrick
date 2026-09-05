import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Selenops
import Structure
import SwiftSoup

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
        let hostScope = WebCrawlerHostScope(initialHosts: request.allowedHosts)
        let fetcher = try AsyncHTTPFetcher(
            hostScope: hostScope,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            proxyToken: proxyToken
        )
        let delegate = WebCrawlerDelegate(
            request: request,
            fetcher: fetcher,
            hostScope: hostScope
        )
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
    private let hostScope: WebCrawlerHostScope
    private let proxyHost: String?
    private let proxyPort: Int?
    private let proxyToken: String?
    private var lastRequestAt: Date?

    init(
        hostScope: WebCrawlerHostScope,
        proxyHost: String?,
        proxyPort: Int?,
        proxyToken: String?
    ) throws {
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
        self.hostScope = hostScope
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
                  let redirectHost = redirectURL.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !redirectHost.isEmpty
            else {
                throw WebCrawlerRuntimeError.redirectOutOfScope
            }

            await hostScope.add(redirectHost)

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
    private let hostScope: WebCrawlerHostScope
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

    init(
        request: ValidatedWebCrawlerRequest,
        fetcher: AsyncHTTPFetcher,
        hostScope: WebCrawlerHostScope
    ) {
        self.request = request
        self.fetcher = fetcher
        self.hostScope = hostScope
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
        guard let host = normalized.host?.lowercased(),
              await hostScope.contains(host)
        else {
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
            guard let host = normalized.host?.lowercased(),
                  await hostScope.contains(host),
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
