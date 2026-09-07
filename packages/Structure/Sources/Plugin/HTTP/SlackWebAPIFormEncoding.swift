import Foundation

/// Slack Web API read methods (`conversations.history`, `conversations.replies`).
///
/// Guest plugins POST JSON (Derrick HTTP contract) or GET with `oldest` and no
/// `inclusive`. Slack rejects JSON on those methods (`invalid_arguments`) and
/// excludes the `oldest` timestamp unless `inclusive` is true, so parent
/// `reply_count` never updates and nested replies are never fetched.
public enum SlackWebAPIFormEncoding: Sendable {
    public struct WireRequest: Equatable, Sendable {
        public var url: String
        public var headers: [String: String]
        public var body: Data?

        public init(url: String, headers: [String: String], body: Data?) {
            self.url = url
            self.headers = headers
            self.body = body
        }
    }

    public static func rewritten(_ request: HostHTTPRequest) -> WireRequest {
        let url = rewrittenURL(request.url)
        guard shouldRewrite(url: request.url),
              let form = formBody(from: request.json)
        else {
            return WireRequest(
                url: url,
                headers: request.wireHeaders,
                body: request.httpBody
            )
        }
        var headers = request.wireHeaders
        headers = headers.filter { $0.key.caseInsensitiveCompare("Content-Type") != .orderedSame }
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        return WireRequest(url: url, headers: headers, body: form)
    }

    public static func shouldRewrite(url: String) -> Bool {
        guard let parsed = URL(string: url),
              let host = parsed.host?.lowercased()
        else {
            return false
        }
        let isSlack = host == "slack.com" || host.hasSuffix(".slack.com")
        guard isSlack else { return false }
        let path = parsed.path.lowercased()
        return path.hasSuffix("/conversations.history") || path.hasSuffix("/conversations.replies")
    }

    public static func rewrittenURL(_ url: String) -> String {
        guard shouldRewrite(url: url),
              var components = URLComponents(string: url)
        else {
            return url
        }
        var items = components.queryItems ?? []
        let names = Set(items.map(\.name))
        let hasBound = names.contains("oldest") || names.contains("latest")
        guard hasBound, !names.contains("inclusive") else {
            return url
        }
        items.append(URLQueryItem(name: "inclusive", value: "true"))
        components.queryItems = items
        return components.string ?? url
    }

    private static func formBody(from json: PluginJSON?) -> Data? {
        guard case .object(let fields) = json else { return nil }
        var pairs: [(String, String)] = fields.keys.sorted().compactMap { key in
            guard let value = scalarString(fields[key]) else { return nil }
            return (key, value)
        }
        let names = Set(pairs.map(\.0))
        let hasBound = names.contains("oldest") || names.contains("since") || names.contains("latest")
        if hasBound, !names.contains("inclusive") {
            pairs.append(("inclusive", "true"))
        }
        let items = pairs.map { "\(encode($0.0))=\(encode($0.1))" }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: "&").data(using: .utf8)
    }

    private static func scalarString(_ json: PluginJSON?) -> String? {
        switch json {
        case .string(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                return String(Int(value))
            }
            return String(value)
        case .null, .array, .object, .none:
            return nil
        }
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=?/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
