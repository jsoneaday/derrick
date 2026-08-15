import Foundation
import Plugin

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

public actor HostHTTPClient {
    public static let shared = HostHTTPClient()

    private var accessGate: any HostHTTPAccessGate = AllowAllHostHTTPAccessGate()
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

    public func perform(method: String, urlString: String, invokeID: String = "") async -> HostHTTPFetch {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return HostHTTPFetch(status: 0, headers: [:], body: "", error: "invalid_url")
        }
        if let denial = PluginSSRFPolicy.denyURL(url) {
            return HostHTTPFetch(status: 0, headers: [:], body: "", error: "ssrf:\(denial)")
        }
        do {
            let addresses = try await resolve(host: url.host ?? "")
            for address in addresses {
                if let denial = PluginSSRFPolicy.denyResolvedAddress(address) {
                    return HostHTTPFetch(status: 0, headers: [:], body: "", error: "ssrf:\(denial)")
                }
            }
        } catch {
            return HostHTTPFetch(status: 0, headers: [:], body: "", error: "dns:\(error.localizedDescription)")
        }

        switch await accessGate.authorize(url: url, invokeID: invokeID) {
        case .allow:
            break
        case .deny(let reason):
            return HostHTTPFetch(status: 0, headers: [:], body: "", error: reason)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            var headers: [String: String] = [:]
            http?.allHeaderFields.forEach { key, value in
                headers["\(key)"] = "\(value)"
            }
            headers = PluginSSRFPolicy.stripResponseHeaders(headers)
            let body = String(decoding: data.prefix(1_048_576), as: UTF8.self)
            return HostHTTPFetch(status: status, headers: headers, body: body, error: nil)
        } catch {
            return HostHTTPFetch(status: 0, headers: [:], body: "", error: error.localizedDescription)
        }
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

/// Rejects HTTP redirects. Host HTTP never follows Location (SSRF / hop pinning).
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
