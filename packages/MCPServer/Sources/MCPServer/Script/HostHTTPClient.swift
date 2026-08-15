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
            json: Data(body.utf8),
            error: PluginFailureSemantics.isFailure(error) ? error : nil
        )
    }
}

public actor HostHTTPClient {
    public static let shared = HostHTTPClient()

    public func perform(method: String, urlString: String) async -> HostHTTPFetch {
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

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("derrick-host-http/1", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
