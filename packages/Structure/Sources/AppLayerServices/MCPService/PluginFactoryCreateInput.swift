import Foundation

/// Host-initiated input for `WorkflowKind.pluginFactoryCreate`.
public struct PluginFactoryCreateInput: Codable, Sendable, Hashable {
    public enum PluginType: String, Codable, Sendable, CaseIterable {
        case connector
        case newsReader = "news_reader"
        case custom
    }

    public enum ConnectorScope: String, Codable, Sendable, CaseIterable {
        case fullSync = "full_sync"

        public var displayName: String { "Full sync" }

        public static var wizardCases: [ConnectorScope] { [.fullSync] }

        public var wizardSubtitle: String {
            "List conversations as tabs, including Slack reply threads, then send and receive."
        }

        public var requiredMessagingOps: [String] {
            if let ops = try? ConnectorContractStore.loadProtocol().scope(id: rawValue).ops,
               !ops.isEmpty {
                return ops
            }
            return ["sync_threads", "poll_inbox", "send_message"]
        }

        /// Older workflow JSON used `send_only` / `send_and_receive`. Those create full sync now.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ConnectorScope(rawValue: raw) ?? .fullSync
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public enum ConnectorVendor: String, Codable, Sendable, CaseIterable {
        case slack
        case telegram
        case whatsapp
        case discord
        case custom

        public var displayName: String {
            switch self {
            case .slack: return "Slack"
            case .telegram: return "Telegram"
            case .whatsapp: return "WhatsApp"
            case .discord: return "Discord"
            case .custom: return "Other"
            }
        }

        /// Slack is the only vendor the wizard will create until others are ready.
        public var isSelectableInWizard: Bool { self == .slack }

        public static func isEnabledMessagingPluginID(_ pluginID: String) -> Bool {
            pluginID.localizedCaseInsensitiveContains("slack")
        }

        /// Primary vendor API documentation entry point for the mandatory crawl step.
        public var documentationStartURL: String? {
            switch self {
            case .slack: return "https://api.slack.com/docs"
            case .telegram: return "https://core.telegram.org/bots/api"
            case .whatsapp: return "https://developers.facebook.com/docs/whatsapp"
            case .discord: return "https://discord.com/developers/docs/intro"
            case .custom: return nil
            }
        }
    }

    public let pluginType: PluginType
    public let vendor: ConnectorVendor?
    public let customVendorName: String?
    public let scope: ConnectorScope
    public let description: String

    public init(
        pluginType: PluginType,
        vendor: ConnectorVendor? = nil,
        customVendorName: String? = nil,
        scope: ConnectorScope = .fullSync,
        description: String
    ) {
        self.pluginType = pluginType
        self.vendor = vendor
        self.customVendorName = customVendorName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.scope = scope
        self.description = Self.resolvedDescription(
            userDescription: description,
            vendor: vendor,
            customVendorName: customVendorName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            scope: scope
        )
    }

    /// Builds connector workflow input. The factory goal uses the fixed scope sentence, not free-text extras.
    public static func makeConnector(
        vendor: ConnectorVendor,
        customVendorName: String? = nil,
        scope: ConnectorScope = .fullSync,
        userDescription: String = ""
    ) -> PluginFactoryCreateInput {
        PluginFactoryCreateInput(
            pluginType: .connector,
            vendor: vendor,
            customVendorName: vendor == .custom ? customVendorName : nil,
            scope: scope,
            description: userDescription
        )
    }

    public static func resolvedDescription(
        userDescription: String,
        vendor: ConnectorVendor?,
        customVendorName: String?,
        scope: ConnectorScope
    ) -> String {
        let trimmed = userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return defaultDescription(vendor: vendor, customVendorName: customVendorName, scope: scope)
    }

    public static func defaultDescription(
        vendor: ConnectorVendor?,
        customVendorName: String?,
        scope: ConnectorScope
    ) -> String {
        _ = scope
        let vendorLabel = vendor?.displayName ?? customVendorName ?? "messaging"
        return """
        List \(vendorLabel) conversations as tabs, load messages for each conversation including reply threads when opened, and send messages.
        """
    }

    enum CodingKeys: String, CodingKey {
        case pluginType
        case vendor
        case customVendorName
        case scope
        case description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginType = try container.decode(PluginType.self, forKey: .pluginType)
        vendor = try container.decodeIfPresent(ConnectorVendor.self, forKey: .vendor)
        customVendorName = try container.decodeIfPresent(String.self, forKey: .customVendorName)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        scope = try container.decodeIfPresent(ConnectorScope.self, forKey: .scope) ?? .fullSync
        let rawDescription = try container.decode(String.self, forKey: .description)
        description = Self.resolvedDescription(
            userDescription: rawDescription,
            vendor: vendor,
            customVendorName: customVendorName,
            scope: scope
        )
    }

    public func encodedJSON() throws -> String {
        let data = try JSONEncoder.service.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return json
    }

    public static func decodeJSON(_ json: String) throws -> PluginFactoryCreateInput {
        try JSONDecoder.service.decode(
            Self.self,
            from: Data(json.utf8)
        )
    }

    /// Factory goal passed to `plugin_factory_build` after vendor docs are crawled.
    public func connectorBuildGoal(crawlSummary: String?) -> String {
        let vendorLabel = vendor?.displayName ?? customVendorName ?? "messaging"
        do {
            return try ConnectorContractPrompts.factoryGoal(
                vendorLabel: vendorLabel,
                scope: scope,
                vendor: vendor,
                crawlSummary: crawlSummary,
                reference: vendor.flatMap {
                    ConnectorReferenceBlueprint.reference(vendor: $0, scope: scope)
                }
            )
        } catch {
            return """
            Create an Agent Plugin messaging connector for \(vendorLabel).
            Scope id: \(scope.rawValue)
            Connector contract failed to load: \(error.localizedDescription)
            """
        }
    }

    /// Failure stage hint for returning the wizard to the right step.
    public enum FailureStep: String, Sendable {
        case type
        case vendor
        case description
        case creating
    }

    public static func failureStep(forStage stage: String?) -> FailureStep {
        switch stage?.lowercased() {
        case "type":
            return .type
        case "crawl", "docs", "vendor", "factory", "build", "review", "description":
            return .vendor
        default:
            return .creating
        }
    }
}

public struct PluginFactoryCreateResult: Codable, Sendable, Hashable {
    public let pluginID: String
    public let version: String
    public let vendor: String
    public let reviewSummary: String

    public init(pluginID: String, version: String, vendor: String, reviewSummary: String) {
        self.pluginID = pluginID
        self.version = version
        self.vendor = vendor
        self.reviewSummary = reviewSummary
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
