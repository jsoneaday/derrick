import Foundation

/// Host-initiated input for `WorkflowKind.pluginFactoryCreate`.
public struct PluginFactoryCreateInput: Codable, Sendable, Hashable {
    public enum PluginType: String, Codable, Sendable, CaseIterable {
        case connector
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

        /// Auth/token docs only. Used before Create so the credential form matches the vendor.
        public var authenticationDocumentationStartURL: String? {
            switch self {
            case .slack: return "https://api.slack.com/authentication/tokens"
            case .telegram: return "https://core.telegram.org/bots/api#authorizing-your-bot"
            case .whatsapp: return "https://developers.facebook.com/docs/whatsapp/cloud-api/get-started"
            case .discord: return "https://discord.com/developers/docs/topics/oauth2"
            case .custom: return nil
            }
        }
    }

    public let pluginType: PluginType
    public let vendor: ConnectorVendor?
    public let customVendorName: String?
    public let scope: ConnectorScope
    public let description: String
    public let pluginID: String?
    public let auth: ConnectorAuthDiscovery?
    public let skillMarkdown: String?

    public init(
        pluginType: PluginType,
        vendor: ConnectorVendor? = nil,
        customVendorName: String? = nil,
        scope: ConnectorScope = .fullSync,
        description: String,
        pluginID: String? = nil,
        auth: ConnectorAuthDiscovery? = nil,
        skillMarkdown: String? = nil
    ) {
        self.pluginType = pluginType
        self.vendor = vendor
        self.customVendorName = customVendorName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.scope = scope
        self.pluginID = pluginID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.auth = auth
        self.skillMarkdown = skillMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.description = Self.resolvedDescription(
            userDescription: description,
            vendor: vendor,
            customVendorName: customVendorName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            scope: scope
        )
    }

    public static func makeFromSkillDraft(
        _ draft: PluginSkillDraft,
        auth: ConnectorAuthDiscovery? = nil
    ) throws -> PluginFactoryCreateInput {
        let pluginID = try draft.normalizedPluginID()
        let description = draft.factoryDescription()
        let skillMarkdown = draft.skillMarkdown()
        switch draft.plannedKind {
        case .messagingConnector:
            guard let vendor = draft.inferredConnectorVendor else {
                throw PluginSkillDraftError.missingConnectorVendor
            }
            return PluginFactoryCreateInput(
                pluginType: .connector,
                vendor: vendor,
                scope: .fullSync,
                description: description,
                pluginID: pluginID,
                auth: auth,
                skillMarkdown: skillMarkdown
            )
        case .customCapability:
            return PluginFactoryCreateInput(
                pluginType: .custom,
                description: description,
                pluginID: pluginID,
                skillMarkdown: skillMarkdown
            )
        }
    }

    /// Builds connector workflow input. The factory goal uses the fixed scope sentence, not free-text extras.
    public static func makeConnector(
        vendor: ConnectorVendor,
        pluginID: String? = nil,
        auth: ConnectorAuthDiscovery? = nil,
        customVendorName: String? = nil,
        scope: ConnectorScope = .fullSync,
        userDescription: String = ""
    ) -> PluginFactoryCreateInput {
        let trimmedID = pluginID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedID = trimmedID.isEmpty
            ? ConnectorPluginNaming.defaultPluginID(vendor: vendor, existingIDs: [])
            : trimmedID
        return PluginFactoryCreateInput(
            pluginType: .connector,
            vendor: vendor,
            customVendorName: vendor == .custom ? customVendorName : nil,
            scope: scope,
            description: userDescription,
            pluginID: resolvedID,
            auth: auth ?? (try? ConnectorAuthDiscovery.slackBotTokenFallback()),
            skillMarkdown: nil
        )
    }

    public var hostManifest: PluginFactoryManifestInput? {
        guard pluginType == .connector, let pluginID, let auth else { return nil }
        return PluginFactoryManifestInput.connector(
            pluginID: pluginID,
            description: description,
            auth: auth,
            messagingOps: scope.requiredMessagingOps
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
        case pluginID
        case auth
        case skillMarkdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginType = try container.decode(PluginType.self, forKey: .pluginType)
        vendor = try container.decodeIfPresent(ConnectorVendor.self, forKey: .vendor)
        customVendorName = try container.decodeIfPresent(String.self, forKey: .customVendorName)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        scope = try container.decodeIfPresent(ConnectorScope.self, forKey: .scope) ?? .fullSync
        let rawDescription = try container.decode(String.self, forKey: .description)
        pluginID = try container.decodeIfPresent(String.self, forKey: .pluginID)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        auth = try container.decodeIfPresent(ConnectorAuthDiscovery.self, forKey: .auth)
        skillMarkdown = try container.decodeIfPresent(String.self, forKey: .skillMarkdown)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        description = Self.resolvedDescription(
            userDescription: rawDescription,
            vendor: vendor,
            customVendorName: customVendorName,
            scope: scope
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pluginType, forKey: .pluginType)
        try container.encodeIfPresent(vendor, forKey: .vendor)
        try container.encodeIfPresent(customVendorName, forKey: .customVendorName)
        try container.encode(scope, forKey: .scope)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(pluginID, forKey: .pluginID)
        try container.encodeIfPresent(auth, forKey: .auth)
        try container.encodeIfPresent(skillMarkdown, forKey: .skillMarkdown)
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
        let summary = crawlSummary ?? auth?.crawlSummary
        do {
            var extra: [String] = []
            if let pluginID {
                extra.append("Host plugin id (do not change): \(pluginID)")
            }
            if let auth {
                extra.append("Host auth_scheme: \(auth.authScheme.rawValue)")
                extra.append(
                    "Host secrets (declare only these ids in HTTP {{secret:id}} placeholders): \(auth.secrets.map(\.id).joined(separator: ", "))"
                )
                if !auth.permissions.isEmpty {
                    extra.append("Host permission labels: \(auth.permissions.joined(separator: ", "))")
                }
            }
            if let skillMarkdown, !skillMarkdown.isEmpty {
                extra.append("SKILL.md draft:\n\(skillMarkdown)")
            }
            extra.append(
                "The host writes plugin.json. Return go_source and test_input_json only. Do not invent a plugin_id or secrets list."
            )
            return try ConnectorContractPrompts.factoryGoal(
                vendorLabel: vendorLabel,
                scope: scope,
                vendor: vendor,
                crawlSummary: summary,
                reference: extra.joined(separator: "\n"),
                includeVendorBindings: true
            )
        } catch {
            return """
            Create an Agent Plugin messaging connector for \(vendorLabel).
            Scope id: \(scope.rawValue)
            Connector contract failed to load: \(error.localizedDescription)
            """
        }
    }

    public func customBuildGoal() -> String {
        var lines = [
            "Create an Agent Plugin capability.",
            description,
        ]
        if let skillMarkdown, !skillMarkdown.isEmpty {
            lines.append("SKILL.md draft:\n\(skillMarkdown)")
        }
        lines.append(
            "Return go_source, test_input_json, and skill_files. Include a valid plugin.json via the builder contract when no host manifest is supplied."
        )
        return lines.joined(separator: "\n\n")
    }

    /// Failure stage hint for returning the plugin studio to the right step.
    public enum FailureStep: String, Sendable {
        case goal
        case skill
        case preview
        case credentials
        case build
    }

    public static func failureStep(forStage stage: String?) -> FailureStep {
        switch stage?.lowercased() {
        case "goal":
            return .goal
        case "skill", "name", "description", "type", "vendor":
            return .skill
        case "preview":
            return .preview
        case "auth", "discover", "credentials":
            return .credentials
        case "crawl", "docs", "factory", "build", "review":
            return .build
        default:
            return .build
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
