import Foundation

public enum SlackUserDisplayNameResolver: Sendable {
    public actor Cache {
        public static let shared = Cache()

        private var names: [String: String] = [:]

        public func displayName(pluginID: String, userID: String) async -> String? {
            let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard MessagingInboundNotificationCopy.isOpaqueVendorActorID(trimmedUserID) else {
                return nil
            }
            let cacheKey = "\(pluginID)|\(trimmedUserID)"
            if let cached = names[cacheKey] {
                return cached
            }
            guard let token = SlackUserDisplayNameResolver.resolveBotToken(pluginID: pluginID),
                  let resolved = await SlackUserDisplayNameResolver.fetchDisplayName(
                    userID: trimmedUserID,
                    token: token
                  )
            else {
                return nil
            }
            names[cacheKey] = resolved
            return resolved
        }

        public func reset() {
            names.removeAll()
        }
    }

    public static func parseDisplayName(from responseJSON: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: responseJSON) as? [String: Any],
              object["ok"] as? Bool == true,
              let user = object["user"] as? [String: Any]
        else {
            return nil
        }
        let profile = user["profile"] as? [String: Any]
        let candidates = [
            profile?["display_name"] as? String,
            user["real_name"] as? String,
            user["name"] as? String,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    static func resolveBotToken(pluginID: String) -> String? {
        for fieldID in ["bot_token", "token", "api_key"] {
            if let value = PluginSecretResolver.resolve(pluginID: pluginID, fieldID: fieldID) {
                return value
            }
        }
        return nil
    }

    static func fetchDisplayName(userID: String, token: String) async -> String? {
        guard var components = URLComponents(string: "https://slack.com/api/users.info") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "user", value: userID)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return parseDisplayName(from: data)
        } catch {
            fputs(
                "[SlackUserDisplayNameResolver] users.info failed user=\(userID): \(error.localizedDescription)\n",
                stderr
            )
            return nil
        }
    }
}

public enum MessagingSenderDisplayName: Sendable {
    public static func resolve(pluginID: String, sender: String) async -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sender }
        guard MessagingInboundNotificationCopy.isOpaqueVendorActorID(trimmed),
              let resolved = await SlackUserDisplayNameResolver.Cache.shared.displayName(
                pluginID: pluginID,
                userID: trimmed
              )
        else {
            return sender
        }
        return resolved
    }
}
