import Foundation

/// Closed connector authentication scheme. Drives the credential form.
/// `oauth` is classified but not collected in the wizard yet.
public enum ConnectorAuthScheme: String, Codable, Sendable, Hashable, CaseIterable {
    case botToken = "bot_token"
    case apiKey = "api_key"
    case basic
    case oauth

    public var displayName: String {
        switch self {
        case .botToken: return "Bot token"
        case .apiKey: return "API key"
        case .basic: return "Username and password"
        case .oauth: return "OAuth"
        }
    }

    public var isSupportedInWizard: Bool { self != .oauth }
}

/// Reviewer-model output and host facts for a connector before the factory runs.
/// `setupHint` and `crawlSummary` are not written to `plugin.json`.
public struct ConnectorAuthDiscovery: Codable, Sendable, Hashable {
    public let authScheme: ConnectorAuthScheme
    public let secrets: [PluginSecretField]
    public let permissions: [String]
    public let setupHint: String?
    public let crawlSummary: String?

    public init(
        authScheme: ConnectorAuthScheme,
        secrets: [PluginSecretField],
        permissions: [String] = [],
        setupHint: String? = nil,
        crawlSummary: String? = nil
    ) {
        self.authScheme = authScheme
        self.secrets = secrets
        self.permissions = permissions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hint = setupHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.setupHint = (hint?.isEmpty == false) ? hint : nil
        let crawl = crawlSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.crawlSummary = (crawl?.isEmpty == false) ? crawl : nil
    }

    enum CodingKeys: String, CodingKey {
        case authScheme = "auth_scheme"
        case secrets
        case permissions
        case setupHint = "setup_hint"
        case crawlSummary = "crawl_summary"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            authScheme: try container.decode(ConnectorAuthScheme.self, forKey: .authScheme),
            secrets: try container.decodeIfPresent([PluginSecretField].self, forKey: .secrets) ?? [],
            permissions: try container.decodeIfPresent([String].self, forKey: .permissions) ?? [],
            setupHint: try container.decodeIfPresent(String.self, forKey: .setupHint),
            crawlSummary: try container.decodeIfPresent(String.self, forKey: .crawlSummary)
        )
    }

    public func withCrawlSummary(_ summary: String?) -> ConnectorAuthDiscovery {
        ConnectorAuthDiscovery(
            authScheme: authScheme,
            secrets: secrets,
            permissions: permissions,
            setupHint: setupHint,
            crawlSummary: summary
        )
    }

    /// Slack bot token when the classifier or crawl is unavailable.
    public static func slackBotTokenFallback(crawlSummary: String? = nil) throws -> ConnectorAuthDiscovery {
        ConnectorAuthDiscovery(
            authScheme: .botToken,
            secrets: [PluginSecretField.slackBotToken],
            permissions: [
                "channels:history",
                "channels:read",
                "chat:write",
                "groups:history",
                "groups:read",
                "im:history",
                "im:read",
                "mpim:history",
                "mpim:read",
                "users:read",
            ],
            setupHint: ConnectorReplyThreadAccessMessage.slackSetupHint,
            crawlSummary: crawlSummary
        )
    }
}

/// Input for `WorkflowKind.connectorAuthDiscover`.
public struct ConnectorAuthDiscoverInput: Codable, Sendable, Hashable {
    public let vendor: PluginFactoryCreateInput.ConnectorVendor
    public let customVendorName: String?

    public init(
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        customVendorName: String? = nil
    ) {
        self.vendor = vendor
        let trimmed = customVendorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.customVendorName = trimmed.isEmpty ? nil : trimmed
    }

    public func encodedJSON() throws -> String {
        let data = try JSONEncoder.service.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return json
    }

    public static func decodeJSON(_ json: String) throws -> ConnectorAuthDiscoverInput {
        try JSONDecoder.service.decode(Self.self, from: Data(json.utf8))
    }
}

/// Crawl-only result. The UI reviewer model classifies auth from `crawlSummary`.
public struct ConnectorAuthDiscoverResult: Codable, Sendable, Hashable {
    public let crawlSummary: String

    public init(crawlSummary: String) {
        self.crawlSummary = crawlSummary
    }

    enum CodingKeys: String, CodingKey {
        case crawlSummary = "crawl_summary"
    }
}

/// Default connector plugin ids: `<vendor>-connector-<n>`.
public enum ConnectorPluginNaming: Sendable {
    public static func prefix(vendor: PluginFactoryCreateInput.ConnectorVendor) -> String {
        "\(vendor.rawValue)-connector"
    }

    public static func defaultPluginID(
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        existingIDs: [String]
    ) -> String {
        let prefix = prefix(vendor: vendor)
        var maxN = 0
        for raw in existingIDs {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if id == prefix {
                maxN = max(maxN, 1)
                continue
            }
            guard id.hasPrefix(prefix + "-") else { continue }
            let suffix = id.dropFirst(prefix.count + 1)
            guard let n = Int(suffix), n > 0 else { continue }
            maxN = max(maxN, n)
        }
        return "\(prefix)-\(maxN + 1)"
    }

    public static func isGeneratedDefault(
        pluginID: String,
        vendor: PluginFactoryCreateInput.ConnectorVendor
    ) -> Bool {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = prefix(vendor: vendor)
        if id == prefix { return true }
        guard id.hasPrefix(prefix + "-") else { return false }
        return Int(id.dropFirst(prefix.count + 1)) != nil
    }
}
