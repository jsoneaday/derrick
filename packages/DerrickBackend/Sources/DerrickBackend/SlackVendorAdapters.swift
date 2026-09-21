import Foundation
import Structure

public struct SlackUserDisplayNameResolver: VendorActorDisplayNameResolving {
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
            guard let token = PluginSecretResolver.resolveCallCredential(pluginID: pluginID),
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

    public init() {}

    public func displayName(pluginID: String, actorID: String) async -> String? {
        await Cache.shared.displayName(pluginID: pluginID, userID: actorID)
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

public struct SlackBotIdentityResolver: VendorSelfActorResolving {
    public actor Cache {
        public static let shared = Cache()

        private var botUserIDs: [String: String] = [:]

        public func botUserID(pluginID: String) async -> String? {
            let trimmedPluginID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPluginID.isEmpty else { return nil }
            if let cached = botUserIDs[trimmedPluginID] {
                return cached
            }
            guard let token = PluginSecretResolver.resolveCallCredential(pluginID: trimmedPluginID),
                  let resolved = await SlackBotIdentityResolver.fetchBotUserID(token: token)
            else {
                return nil
            }
            botUserIDs[trimmedPluginID] = resolved
            return resolved
        }

        public func reset() {
            botUserIDs.removeAll()
        }
    }

    public init() {}

    public func selfActorID(pluginID: String) async -> String? {
        await Cache.shared.botUserID(pluginID: pluginID)
    }

    public static func parseBotUserID(from responseJSON: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: responseJSON) as? [String: Any],
              object["ok"] as? Bool == true
        else {
            return nil
        }
        let candidates = [
            object["user_id"] as? String,
            object["bot_id"] as? String,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    static func fetchBotUserID(token: String) async -> String? {
        guard let url = URL(string: "https://slack.com/api/auth.test") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return parseBotUserID(from: data)
        } catch {
            return nil
        }
    }
}

/// Install Slack adapters. Structure stays vendor-neutral.
public enum SlackVendorHost: Sendable {
    public static func install() async {
        await VendorActorDirectory.shared.setDisplayNameResolver(SlackUserDisplayNameResolver())
        await VendorActorDirectory.shared.setSelfActorResolver(SlackBotIdentityResolver())
    }
}
