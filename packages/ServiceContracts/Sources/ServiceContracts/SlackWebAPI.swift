import Foundation

public struct SlackChannel: Sendable, Hashable {
    public let id: String
    public let name: String
    public let isMember: Bool

    public init(id: String, name: String, isMember: Bool) {
        self.id = id
        self.name = name
        self.isMember = isMember
    }
}

public struct SlackMessage: Sendable, Hashable {
    public let timestamp: String
    public let userID: String?
    public let text: String
    public let botID: String?

    public init(timestamp: String, userID: String?, text: String, botID: String?) {
        self.timestamp = timestamp
        self.userID = userID
        self.text = text
        self.botID = botID
    }

    public var createdAt: Date {
        Self.date(fromSlackTimestamp: timestamp) ?? .now
    }

    public static func date(fromSlackTimestamp raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed) else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}

/// Host-owned Slack Web API client. Secrets stay outside guest plugins.
public struct SlackWebAPI: Sendable {
    public enum APIError: Error, LocalizedError, Equatable {
        case missingToken
        case invalidResponse
        case slackError(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken:
                return "A Slack bot token is required."
            case .invalidResponse:
                return "Slack returned an invalid response."
            case .slackError(let code):
                return "Slack error: \(code)"
            }
        }
    }

    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func authTest() async throws -> (userID: String, team: String) {
        let payload = try await request(method: "GET", path: "auth.test")
        let userID = try string(payload, key: "user_id")
        let team = try string(payload, key: "team")
        return (userID, team)
    }

    public func listMemberChannels() async throws -> [SlackChannel] {
        var channels: [SlackChannel] = []
        var cursor: String?
        repeat {
            var query = [
                URLQueryItem(name: "types", value: "public_channel,private_channel"),
                URLQueryItem(name: "exclude_archived", value: "true"),
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let payload = try await request(method: "GET", path: "conversations.list", query: query)
            let page = payload["channels"] as? [[String: Any]] ?? []
            for row in page {
                guard let id = row["id"] as? String,
                      let name = row["name"] as? String else {
                    continue
                }
                let isMember = (row["is_member"] as? Bool) == true
                if isMember {
                    channels.append(SlackChannel(id: id, name: name, isMember: true))
                }
            }
            let metadata = payload["response_metadata"] as? [String: Any]
            cursor = metadata?["next_cursor"] as? String
            if cursor?.isEmpty == true { cursor = nil }
        } while cursor != nil
        return channels.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func fetchHistory(channelID: String, limit: Int = 50) async throws -> [SlackMessage] {
        let payload = try await request(
            method: "GET",
            path: "conversations.history",
            query: [
                URLQueryItem(name: "channel", value: channelID),
                URLQueryItem(name: "limit", value: String(max(1, min(limit, 100)))),
            ]
        )
        let rows = payload["messages"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.decodeMessage)
    }

    public func postMessage(channelID: String, text: String) async throws -> SlackMessage {
        let payload = try await request(
            method: "POST",
            path: "chat.postMessage",
            jsonBody: [
                "channel": channelID,
                "text": text,
            ]
        )
        guard let message = payload["message"] as? [String: Any],
              let parsed = Self.decodeMessage(message) else {
            throw APIError.invalidResponse
        }
        return parsed
    }

    static func decodeMessage(_ row: [String: Any]) -> SlackMessage? {
        guard let timestamp = row["ts"] as? String else { return nil }
        let text = (row["text"] as? String) ?? ""
        let userID = row["user"] as? String
        let botID = row["bot_id"] as? String
        return SlackMessage(timestamp: timestamp, userID: userID, text: text, botID: botID)
    }

    private func request(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        jsonBody: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard !token.isEmpty else { throw APIError.missingToken }
        var components = URLComponents(string: "https://slack.com/api/\(path)")!
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw APIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        if payload["ok"] as? Bool != true {
            let error = payload["error"] as? String ?? "unknown_error"
            if error == "missing_scope", let needed = payload["needed"] as? String, !needed.isEmpty {
                throw APIError.slackError(
                    "missing_scope (add Bot Token Scope “\(needed)” in api.slack.com, then Reinstall to Workspace and update your token)"
                )
            }
            throw APIError.slackError(error)
        }
        return payload
    }

    private func string(_ payload: [String: Any], key: String) throws -> String {
        guard let value = payload[key] as? String, !value.isEmpty else {
            throw APIError.invalidResponse
        }
        return value
    }
}
