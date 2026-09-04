import Foundation
import Network
import Testing
@testable import WebCrawler

@Suite
struct WebCrawlerTests {
    @Test
    func validatesSafeRequestAndNormalizesStartURL() throws {
        let request = WebCrawlerRequest(
            startURL: "HTTPS://Example.com",
            goal: "Show the main content",
            maxPages: 3,
            maxDepth: 1,
            timeoutSeconds: 90
        )

        let validated = try request.validated()

        #expect(validated.startURL.absoluteString == "https://example.com/")
        #expect(validated.maxPages == 3)
        #expect(validated.maxDepth == 1)
        #expect(validated.timeoutSeconds == 90)
    }

    @Test
    func rejectsTimeoutAboveFifteenMinutes() {
        let request = WebCrawlerRequest(
            startURL: "https://example.com",
            goal: "Read the page",
            timeoutSeconds: WebCrawlerLimits.maximumTimeoutSeconds + 1
        )

        #expect(throws: WebCrawlerValidationError.invalidTimeout) {
            _ = try request.validated()
        }
    }

    @Test
    func rejectsDDoSLikeGoals() {
        let request = WebCrawlerRequest(
            startURL: "https://example.com",
            goal: "Flood the site with requests"
        )

        #expect(throws: WebCrawlerValidationError.maliciousGoal(
            "flooding a website is not allowed."
        )) {
            _ = try request.validated()
        }
    }

    @Test
    func rejectsCredentialBearingURLs() {
        let request = WebCrawlerRequest(
            startURL: "https://user:password@example.com",
            goal: "Read the page"
        )

        #expect(throws: WebCrawlerValidationError.invalidStartURL) {
            _ = try request.validated()
        }
    }

    @Test
    func resultRoundTripsWithStructuredStopReason() throws {
        let result = WebCrawlerResult(
            ok: true,
            startURL: "https://example.com/",
            pages: [
                WebCrawlerPage(
                    url: "https://example.com/",
                    depth: 0,
                    statusCode: 200,
                    contentType: "text/html",
                    title: "Example",
                    text: "Example Domain",
                    linksFound: 0
                )
            ],
            stopReason: .completed,
            requestsMade: 1,
            bytesRead: 1_024,
            truncated: false,
            diagnostics: []
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(WebCrawlerResult.self, from: data)

        #expect(decoded == result)
        #expect(String(decoding: data, as: UTF8.self).contains("\"stop_reason\":\"completed\""))
    }

    @Test
    func rejectsInfiniteLoopGoals() {
        let request = WebCrawlerRequest(
            startURL: "https://example.com",
            goal: "Crawl forever in an infinite loop"
        )

        #expect(throws: WebCrawlerValidationError.maliciousGoal(
            "unbounded or infinite crawling is not allowed."
        )) {
            _ = try request.validated()
        }
    }

    @Test
    func cyclicPagesStopAtMaxPages() async throws {
        let server = try LoopbackHTTPServer(pages: [
            "/": "<html><body><h1>Home</h1><a href=\"/\">home</a><a href=\"/a\">a</a></body></html>",
            "/a": "<html><body><h1>A</h1><a href=\"/\">home</a><a href=\"/a\">a</a><a href=\"/b\">b</a></body></html>",
            "/b": "<html><body><h1>B</h1><a href=\"/a\">a</a></body></html>"
        ])
        try await server.start()
        defer { server.stop() }

        let started = Date()
        let result = await WebCrawlerEngine.run(
            request: WebCrawlerRequest(
                startURL: "http://127.0.0.1:\(server.port)/",
                goal: "Read the linked pages",
                maxPages: 2,
                maxDepth: 5,
                timeoutSeconds: 8
            )
        )

        #expect(Date().timeIntervalSince(started) < 8)
        #expect(result.pages.count <= 2)
        #expect(result.requestsMade <= 2)
        #expect(result.stopReason == .maxPages || result.stopReason == .completed)
        #expect(result.pages.allSatisfy { $0.url.contains("127.0.0.1") })
    }

    @Test
    func staysOnStartOrigin() async throws {
        let server = try LoopbackHTTPServer(pages: [
            "/": """
            <html><body>
            <a href="/about">about</a>
            <a href="https://example.com/offsite">offsite</a>
            </body></html>
            """,
            "/about": "<html><body><h1>About</h1></body></html>"
        ])
        try await server.start()
        defer { server.stop() }

        let result = await WebCrawlerEngine.run(
            request: WebCrawlerRequest(
                startURL: "http://127.0.0.1:\(server.port)/",
                goal: "Read local pages only",
                maxPages: 10,
                maxDepth: 2,
                timeoutSeconds: 8
            )
        )

        #expect(!result.pages.isEmpty)
        #expect(result.pages.allSatisfy { $0.url.contains("127.0.0.1") })
        #expect(!result.pages.contains { $0.url.contains("example.com") })
    }

    @Test
    func validatedRequestAcceptsExplicitAllowedHosts() throws {
        let validated = try WebCrawlerRequest(
            startURL: "https://api.slack.com/web",
            goal: "Read Slack API docs",
            allowedHosts: ["api.slack.com", "docs.slack.dev"]
        ).validated()

        #expect(validated.allowedHosts.contains("api.slack.com"))
        #expect(validated.allowedHosts.contains("docs.slack.dev"))
    }

    @Test
    func stopsWhenTimeoutElapses() async throws {
        let server = try LoopbackHTTPServer(
            pages: [
                "/": "<html><body><h1>Slow</h1></body></html>"
            ],
            delayMilliseconds: 2_500
        )
        try await server.start()
        defer { server.stop() }

        let started = Date()
        let result = await WebCrawlerEngine.run(
            request: WebCrawlerRequest(
                startURL: "http://127.0.0.1:\(server.port)/",
                goal: "Read the slow page",
                maxPages: 5,
                maxDepth: 1,
                timeoutSeconds: 1
            )
        )

        #expect(Date().timeIntervalSince(started) < 5)
        #expect(result.stopReason == .timeout)
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "derrick.webcrawler.test.http")
    private let pages: [String: String]
    private let redirects: [String: String]
    private let delayMilliseconds: Int

    var port: Int {
        Int(listener.port?.rawValue ?? 0)
    }

    init(
        pages: [String: String] = [:],
        redirects: [String: String] = [:],
        delayMilliseconds: Int = 0
    ) throws {
        self.pages = pages
        self.redirects = redirects
        self.delayMilliseconds = delayMilliseconds
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            if self.delayMilliseconds > 0 {
                Thread.sleep(forTimeInterval: Double(self.delayMilliseconds) / 1_000)
            }
            let path = Self.path(from: request)
            if let redirect = self.redirects[path] {
                let location = redirect.hasPrefix("http") ? redirect : redirect
                let response = """
                HTTP/1.1 302 Found\r
                Location: \(location)\r
                Content-Length: 0\r
                Connection: close\r
                \r
                """
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
                return
            }
            let body = self.pages[path] ?? "<html><body>not found</body></html>"
            let status = self.pages[path] == nil ? "404 Not Found" : "200 OK"
            let response = """
            HTTP/1.1 \(status)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in
                    connection.cancel()
                }
            )
        }
    }

    private static func path(from request: String) -> String {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        let target = String(parts[1])
        guard let url = URL(string: target) else {
            return target.split(separator: "?").first.map(String.init) ?? "/"
        }
        let path = url.path.isEmpty ? "/" : url.path
        return path
    }
}
