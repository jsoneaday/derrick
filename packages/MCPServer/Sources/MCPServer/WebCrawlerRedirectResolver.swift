import Foundation
import WebCrawler

/// Host-side redirect discovery for crawler egress leases and allowed-host injection.
enum WebCrawlerRedirectResolver: Sendable {
    private final class RedirectProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: RedirectProbeDelegate(),
            delegateQueue: nil
        )
    }()

    static func hostsInRedirectChain(
        from startURL: URL,
        maxRedirects: Int = WebCrawlerLimits.maximumRedirectsPerPage
    ) async -> Set<String> {
        var hosts: Set<String> = []
        if let startHost = startURL.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !startHost.isEmpty {
            hosts.insert(startHost)
        }

        var current = normalize(startURL)
        for _ in 0..<maxRedirects {
            var request = URLRequest(url: current)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 20
            request.setValue("DerrickWebCrawlerRedirectProbe/1", forHTTPHeaderField: "User-Agent")

            guard let (_, response) = try? await probeSession.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (300..<400).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL,
                  isHTTP(next),
                  let host = next.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !host.isEmpty
            else {
                break
            }

            hosts.insert(host)
            current = normalize(next)
        }

        return hosts
    }

    private static func isHTTP(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func normalize(_ url: URL) -> URL {
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
}
