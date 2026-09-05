import Foundation
import Plugin
import Structure

public struct HostHTTPFetch: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: String
    public var error: String?

    public var succeeded: Bool { !PluginFailureSemantics.isFailure(error) }

    public func response(requestID: String) -> HostHTTPResponse {
        HostHTTPResponse(
            requestID: requestID,
            status: status,
            headers: headers,
            body: body,
            error: PluginFailureSemantics.isFailure(error) ? error : nil
        )
    }
}

public protocol HostHTTPSecretAttacher: Sendable {
    func apply(url: URL) async -> (url: URL, headers: [String: String])
}

public actor HostHTTPClient {
    public static let shared = HostHTTPClient()

    private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
    private static let maxRedirects = 5

    private var accessGate: any HostHTTPAccessGate = AllowAllHostHTTPAccessGate()
    private var secretAttacher: (any HostHTTPSecretAttacher)?
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: config,
            delegate: HostHTTPRedirectDenyingDelegate(),
            delegateQueue: nil
        )
    }

    public func setAccessGate(_ gate: any HostHTTPAccessGate) {
        accessGate = gate
    }

    public func setSecretAttacher(_ attacher: (any HostHTTPSecretAttacher)?) {
        secretAttacher = attacher
    }

    public func perform(method: String, urlString: String, invokeID: String = "") async -> HostHTTPFetch {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return HostHTTPFetch(status: 0, headers: [:], body: "", error: "invalid_url")
        }
        var currentURL = url
        var currentMethod = method
        var visitedURLs = Set([url.absoluteString])

        for redirectIndex in 0...Self.maxRedirects {
            if let preflightError = await preflight(currentURL, invokeID: invokeID) {
                return HostHTTPFetch(status: 0, headers: [:], body: "", error: preflightError)
            }

            let request = await makeRequest(method: currentMethod, url: currentURL)
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return HostHTTPFetch(status: 0, headers: [:], body: "", error: "invalid_response")
                }

                let status = http.statusCode
                var headers: [String: String] = [:]
                http.allHeaderFields.forEach { key, value in
                    headers["\(key)"] = "\(value)"
                }
                headers = PluginSSRFPolicy.stripResponseHeaders(headers)

                guard Self.redirectStatuses.contains(status) else {
                    let body = String(decoding: data.prefix(1_048_576), as: UTF8.self)
                    return HostHTTPFetch(status: status, headers: headers, body: body, error: nil)
                }
                guard redirectIndex < Self.maxRedirects else {
                    return HostHTTPFetch(status: status, headers: headers, body: "", error: "redirect_limit")
                }
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let redirectURL = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                    return HostHTTPFetch(status: status, headers: headers, body: "", error: "redirect_invalid_location")
                }
                guard visitedURLs.insert(redirectURL.absoluteString).inserted else {
                    return HostHTTPFetch(status: status, headers: headers, body: "", error: "redirect_loop")
                }

                currentURL = redirectURL
                if status == 303 {
                    currentMethod = "GET"
                }
            } catch {
                return HostHTTPFetch(status: 0, headers: [:], body: "", error: error.localizedDescription)
            }
        }

        return HostHTTPFetch(status: 0, headers: [:], body: "", error: "redirect_limit")
    }

    private func preflight(_ url: URL, invokeID: String) async -> String? {
        if let denial = PluginSSRFPolicy.denyURL(url) {
            return "ssrf:\(denial)"
        }
        do {
            let addresses = try await resolve(host: url.host ?? "")
            for address in addresses {
                if let denial = PluginSSRFPolicy.denyResolvedAddress(address) {
                    return "ssrf:\(denial)"
                }
            }
        } catch {
            return "dns:\(error.localizedDescription)"
        }

        switch await accessGate.authorize(url: url, invokeID: invokeID) {
        case .allow:
            return nil
        case .deny(let reason):
            return reason
        }
    }

    private func makeRequest(method: String, url: URL) async -> URLRequest {
        var requestURL = url
        var extraHeaders: [String: String] = [:]
        if let secretAttacher {
            let attached = await secretAttacher.apply(url: url)
            requestURL = attached.url
            extraHeaders = attached.headers
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        for (header, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func resolve(host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var hints = addrinfo(
                    ai_flags: AI_ADDRCONFIG,
                    ai_family: AF_UNSPEC,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                guard status == 0, let first = result else {
                    continuation.resume(throwing: NSError(
                        domain: "HostHTTP",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "DNS failed for \(host)"]
                    ))
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor {
                    if let sockaddr = info.pointee.ai_addr {
                        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(
                            sockaddr,
                            socklen_t(info.pointee.ai_addrlen),
                            &hostBuffer,
                            socklen_t(hostBuffer.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        ) == 0 {
                            addresses.append(String(cString: hostBuffer))
                        }
                    }
                    cursor = info.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}

/// Stops URLSession from following redirects automatically. HostHTTPClient follows
/// redirects itself after rechecking SSRF, DNS, and access policy at every hop.
private final class HostHTTPRedirectDenyingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        _ = response
        _ = request
        completionHandler(nil)
    }
}
