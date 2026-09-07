import Foundation

public struct MessagingAgentRoute: Sendable, Hashable {
    public let pluginID: String
    public let threadID: String
    public let vendorThreadID: String
    public let parentVendorMessageID: String?
    public let inboundVendorMessageID: String
    public let profileHandle: String
    public let prompt: String

    public init(
        pluginID: String,
        threadID: String,
        vendorThreadID: String,
        parentVendorMessageID: String?,
        inboundVendorMessageID: String,
        profileHandle: String,
        prompt: String
    ) {
        self.pluginID = pluginID
        self.threadID = threadID
        self.vendorThreadID = vendorThreadID
        self.parentVendorMessageID = parentVendorMessageID
        self.inboundVendorMessageID = inboundVendorMessageID
        self.profileHandle = profileHandle
        self.prompt = prompt
    }
}

/// Parses connector message bodies for bot mentions and `$handle` profile tokens.
public enum ConnectorMentionParser: Sendable {
    public static let botReplyPrefix = "[\(DerrickAppSupport.hostAppProductName)]"

    public static func mentionsSlackUser(body: String, userID: String) -> Bool {
        let trimmedID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return false }
        return body.contains("<@\(trimmedID)>")
            || body.contains("<@\(trimmedID)|")
    }

    public static func stripSlackUserMention(body: String, userID: String) -> String {
        let trimmedID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return body }
        let pattern = #"<@\#(trimmedID)(?:\|[^>]+)?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return body
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let stripped = regex.stringByReplacingMatches(in: body, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isAutomatedOutboundEcho(body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix(botReplyPrefix)
    }

    public static func resolvePrompt(
        body: String,
        botUserID: String
    ) -> (profileHandle: String, prompt: String)? {
        guard mentionsSlackUser(body: body, userID: botUserID) else { return nil }
        let withoutMention = stripSlackUserMention(body: body, userID: botUserID)
        let parsed = AgentProfileTokenParser.parse(message: withoutMention)
        let handle = parsed.handle ?? AgentProfileHandle.orchestrator
        let prompt = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return (handle, defaultMentionOnlyPrompt)
        }
        return (handle, prompt)
    }

    public static let defaultMentionOnlyPrompt =
        "The user mentioned Derrick without a specific request. Briefly explain they can use $profileName in their message (for example $orchestrator) and offer to help."
}

public enum SlackBotIdentityResolver: Sendable {
    public actor Cache {
        public static let shared = Cache()

        private var botUserIDs: [String: String] = [:]

        public func botUserID(pluginID: String) async -> String? {
            let trimmedPluginID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPluginID.isEmpty else { return nil }
            if let cached = botUserIDs[trimmedPluginID] {
                return cached
            }
            guard let token = SlackUserDisplayNameResolver.resolveBotToken(pluginID: trimmedPluginID),
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

public enum MessagingAgentSessionID {
    public static func make(pluginID: String, threadID: String, profileHandle: String) -> String {
        "messaging-\(pluginID)-\(threadID)-\(profileHandle)"
    }
}

public enum MessagingAgentOutboundFormatter {
    public static func formatReply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(ConnectorMentionParser.botReplyPrefix) \(trimmed)"
    }
}
