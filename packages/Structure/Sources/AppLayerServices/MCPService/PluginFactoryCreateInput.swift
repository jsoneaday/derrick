import Foundation

/// Host-initiated input for `WorkflowKind.pluginFactoryCreate`.
public struct PluginFactoryCreateInput: Codable, Sendable, Hashable {
    public enum PluginType: String, Codable, Sendable, CaseIterable {
        case connector
        case newsReader = "news_reader"
        case custom
    }

    public enum ConnectorScope: String, Codable, Sendable, CaseIterable {
        case sendOnly = "send_only"
        case sendAndReceive = "send_and_receive"
        case fullSync = "full_sync"

        public var displayName: String {
            switch self {
            case .sendOnly: return "Send only"
            case .sendAndReceive: return "Send + receive"
            case .fullSync: return "Full sync"
            }
        }

        /// Scopes offered in the create-connector wizard. Send-only and full-sync
        /// remain decodable for older workflows and already-installed plugins.
        public static var wizardCases: [ConnectorScope] {
            [.sendAndReceive]
        }

        public var wizardSubtitle: String {
            switch self {
            case .sendOnly:
                return "Post messages to a channel. Fastest to build and review."
            case .sendAndReceive:
                return "List conversations, pick one, then send and receive new messages."
            case .fullSync:
                return "List conversations, pull full history including thread replies, paginate, and send."
            }
        }

        var scopeRequirement: String {
            switch self {
            case .sendOnly:
                return """
                Scope: send_message only. Do not implement sync_threads or poll_inbox unless the user requirements explicitly ask for them.
                """
            case .sendAndReceive:
                return """
                Scope: sync_threads, send_message, and poll_inbox for one conversation at a time.
                Implement sync_threads when the vendor uses opaque conversation IDs that differ from human-readable labels (read vendor docs).
                sync_threads result.emit must map each conversation the secret can access to {vendor_thread_id, title} so the host can show a channel picker.
                For Slack, skip channels where is_member is false. Do not list public channels the bot is not in.
                Do not fetch thread replies unless the user requirements explicitly require them.
                For send + receive, single-page sync_threads and poll_inbox are correct — do not paginate in tests unless you include http_results fixtures for every extra request_id you emit.
                """
            case .fullSync:
                return """
                Scope: sync_threads, poll_inbox, and send_message with pagination.
                Include thread replies when the vendor supports them and the user requirements expect full conversation history.
                """
            }
        }

        var requiredMessagingOps: [String] {
            switch self {
            case .sendOnly: return ["send_message"]
            case .sendAndReceive: return ["sync_threads", "poll_inbox", "send_message"]
            case .fullSync: return ["sync_threads", "poll_inbox", "send_message"]
            }
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
        scope: ConnectorScope = .sendAndReceive,
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

    /// Builds connector workflow input, using scope-based defaults when the user leaves details blank.
    public static func makeConnector(
        vendor: ConnectorVendor,
        customVendorName: String? = nil,
        scope: ConnectorScope,
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
        let vendorLabel = vendor?.displayName ?? customVendorName ?? "messaging"
        switch scope {
        case .sendOnly:
            return "Send messages through \(vendorLabel)."
        case .sendAndReceive:
            return "Send messages and receive new messages from one \(vendorLabel) conversation."
        case .fullSync:
            return """
            Fully sync \(vendorLabel): list channels, paginate conversation history (including threads where supported), and send messages.
            """
        }
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
        scope = try container.decodeIfPresent(ConnectorScope.self, forKey: .scope) ?? .sendAndReceive
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
        var parts: [String] = [
            "Create an Agent Plugin messaging connector for \(vendorLabel).",
            "Set extensions.app.derrick.role to connector.",
            "Declare messaging_ops: \(scope.requiredMessagingOps.map { "\"\($0)\"" }.joined(separator: ", ")).",
            scope.scopeRequirement,
            """
            test_input_json must include a hops array with http_results fixtures that exercise every messaging_op you implement \
            (\(scope.requiredMessagingOps.joined(separator: ", "))) through to result.emit.
            """,
            "User requirements: \(description)",
        ]
        if let vendor, let reference = ConnectorReferenceBlueprint.reference(vendor: vendor, scope: scope) {
            parts.append(reference)
        }
        if let pagination = PluginFactoryScopeHints.paginationGuidance(for: parts.joined(separator: "\n")) {
            parts.append(pagination)
        }
        if let crawlSummary, !crawlSummary.isEmpty {
            parts.append("Reference these crawled vendor API notes:\n\(crawlSummary)")
        }
        return parts.joined(separator: "\n\n")
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
        case "crawl", "docs":
            return .vendor
        case "factory", "build", "review":
            return .description
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
