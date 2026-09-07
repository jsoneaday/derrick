import Foundation
import Testing
import Structure

@Suite struct NewsReaderTests {
    @Test func paywallWarningIsUserFacing() {
        #expect(NewsPaywall.userWarning.localizedCaseInsensitiveContains("paywall"))
        #expect(NewsPaywall.userWarning.localizedCaseInsensitiveContains("not supported"))
    }

    @Test func preflightRejectsPaywalledArticleAllowsFeed() {
        #expect(
            NewsPaywall.preflightRejection(
                url: URL(string: "https://www.nytimes.com/2024/01/01/world.html")!
            ) != nil
        )
        #expect(
            NewsPaywall.preflightRejection(
                url: URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml")!
            ) == nil
        )
        #expect(
            NewsPaywall.preflightRejection(
                url: URL(string: "https://feeds.bbci.co.uk/news/rss.xml")!
            ) == nil
        )
    }

    @Test func knownPaywallHostIsDetected() {
        #expect(NewsPaywall.hostLooksPaywalled(URL(string: "https://www.nytimes.com/2024/01/01/world.html")!))
        #expect(!NewsPaywall.hostLooksPaywalled(URL(string: "https://feeds.bbci.co.uk/news/rss.xml")!))
    }

    @Test func htmlPaywallIsRejected() {
        let html = "<html><body>Subscribe to continue reading this article</body></html>"
        let reason = NewsPaywall.rejectionReason(
            url: URL(string: "https://www.nytimes.com/story")!,
            status: 200,
            contentType: "text/html",
            body: Data(html.utf8)
        )
        #expect(reason != nil)
        #expect(reason?.localizedCaseInsensitiveContains("paywall") == true)
    }

    @Test func rssFromPaywalledPublisherIsAllowed() {
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Feed</title></channel></rss>
        """
        let reason = NewsPaywall.rejectionReason(
            url: URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml")!,
            status: 200,
            contentType: "application/rss+xml",
            body: Data(rss.utf8)
        )
        #expect(reason == nil)
    }

    @Test func parserReadsRssItemsWithLinks() {
        let rss = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
        <item><title>Hello world</title><link>https://example.com/hello</link><description>Body</description></item>
        </channel></rss>
        """
        let entries = NewsFeedParser.parse(
            data: Data(rss.utf8),
            sourceLabel: "Example",
            fallbackPageURL: URL(string: "https://example.com/feed")!
        )
        #expect(entries.count == 1)
        #expect(entries[0].title == "Hello world")
        #expect(entries[0].sourceURL == "https://example.com/hello")
    }

    @Test func refreshFailsPaywalledURL() async throws {
        let client = StubNewsClient(response: NewsHTTPResponse(
            status: 200,
            contentType: "text/html",
            body: Data("<html>This article is for subscribers only</html>".utf8)
        ))
        let spec = NewsReaderSpec(
            name: "Test",
            topics: [],
            sources: [NewsSource(label: "NYT", url: "https://www.nytimes.com/story")]
        )
        do {
            _ = try await NewsReaderRefresh.validateAndFetch(spec: spec, client: client)
            Issue.record("expected paywall failure")
        } catch let error as NewsReaderError {
            guard case .paywalled = error else {
                Issue.record("expected paywalled, got \(error)")
                return
            }
        }
    }

    @Test func refreshReturnsLinkedItemsCapped() async throws {
        let rss = """
        <?xml version="1.0"?><rss><channel>
        <item><title>One</title><link>https://example.com/1</link></item>
        <item><title>Two</title><link>https://example.com/2</link></item>
        <item><title>Three</title><link>https://example.com/3</link></item>
        </channel></rss>
        """
        let client = StubNewsClient(response: NewsHTTPResponse(
            status: 200,
            contentType: "application/rss+xml",
            body: Data(rss.utf8)
        ))
        let spec = NewsReaderSpec(
            name: "Cap",
            topics: [],
            sources: [NewsSource(label: "Ex", url: "https://example.com/rss.xml")],
            maxCount: 2
        )
        let items = try await NewsReaderRefresh.validateAndFetch(spec: spec, client: client)
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.sourceURL.isEmpty })
    }

    @Test func googleNewsHomepageMapsToRSS() {
        let mapped = NewsSourceURL.canonicalFetchURL(URL(string: "https://news.google.com/")!)
        #expect(mapped.host == "news.google.com")
        #expect(mapped.path == "/rss")
        let already = NewsSourceURL.canonicalFetchURL(
            URL(string: "https://news.google.com/rss?hl=en-US")!
        )
        #expect(already.path.contains("rss"))
    }

    @Test func refreshParsesGoogleNewsHomepageViaRSS() async throws {
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item><title>World headline</title><link>https://news.google.com/articles/abc</link><description>Summary bit</description></item>
        </channel></rss>
        """
        let client = StubNewsClient(response: NewsHTTPResponse(
            status: 200,
            contentType: "application/rss+xml",
            body: Data(rss.utf8)
        ))
        let spec = NewsReaderSpec(
            name: "Google",
            topics: [],
            sources: [NewsSource(label: "Google News", url: "https://news.google.com")],
            mode: .summaries,
            maxCount: 10
        )
        let items = try await NewsReaderRefresh.validateAndFetch(spec: spec, client: client)
        #expect(items.count == 1)
        #expect(items[0].title == "World headline")
        #expect(items[0].sourceURL.contains("news.google.com"))
        #expect(NewsReaderRefresh.digest(from: items).contains("World headline"))
    }

    @Test func liveGoogleNewsRSSHasLinkedSummaries() async throws {
        let spec = NewsReaderSpec(
            name: "Google live",
            topics: [],
            sources: [NewsPresetSource.googleNews.source],
            mode: .summaries,
            maxCount: 8
        )
        let items = try await NewsReaderRefresh.validateAndFetch(
            spec: spec,
            client: URLSessionNewsHTTPClient()
        )
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { !$0.sourceURL.isEmpty && !$0.title.isEmpty })
        #expect(!NewsReaderRefresh.digest(from: items).isEmpty)
    }

    private struct StubNewsClient: NewsHTTPClient {
        let response: NewsHTTPResponse
        func get(url: URL) async throws -> NewsHTTPResponse { response }
    }
}
