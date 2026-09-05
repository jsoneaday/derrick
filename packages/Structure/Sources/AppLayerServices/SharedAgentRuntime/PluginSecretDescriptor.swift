import Foundation

/// User-visible plugin credential declaration. Values are never included.
public struct PluginSecretDescriptor: Codable, Sendable, Hashable {
    public let id: String
    public let label: String
    public let kind: String

    public init(id: String, label: String, kind: String) {
        self.id = id
        self.label = label
        self.kind = kind
    }

    public var usesSecureField: Bool {
        switch kind {
        case "password", "token", "api_key":
            return true
        default:
            return false
        }
    }
}

/// Reverse-XPC / approval tool name for collecting plugin Keychain secrets.
public enum PluginCredentialPrompt {
    public static let toolName = "plugin.credentials"
}

public enum PluginCredentialCollectionMode: String, Codable, Sendable, Hashable {
    /// User must supply every field that is not already in Keychain.
    case requireMissing
    /// Show all fields obfuscated; only non-empty drafts are written.
    case allowPartialUpdate
}

public struct PluginCredentialFieldPresentation: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let kind: String
    public let hasStoredValue: Bool

    public init(id: String, label: String, kind: String, hasStoredValue: Bool) {
        self.id = id
        self.label = label
        self.kind = kind
        self.hasStoredValue = hasStoredValue
    }

    public var descriptor: PluginSecretDescriptor {
        PluginSecretDescriptor(id: id, label: label, kind: kind)
    }

    public var usesSecureField: Bool {
        descriptor.usesSecureField
    }

    public static func presentations(
        for descriptors: [PluginSecretDescriptor],
        pluginID: String
    ) -> [PluginCredentialFieldPresentation] {
        descriptors.map { descriptor in
            let stored = PluginSecretKeychain.hasStoredValue(
                pluginID: pluginID,
                fieldID: descriptor.id
            )
            return PluginCredentialFieldPresentation(
                id: descriptor.id,
                label: descriptor.label,
                kind: descriptor.kind,
                hasStoredValue: stored
            )
        }
    }
}

public struct PluginCredentialPromptPayload: Codable, Sendable, Hashable {
    public let pluginID: String
    public let fields: [PluginCredentialFieldPresentation]
    public let mode: PluginCredentialCollectionMode

    public init(
        pluginID: String,
        secrets: [PluginSecretDescriptor],
        mode: PluginCredentialCollectionMode
    ) {
        self.pluginID = pluginID
        self.fields = PluginCredentialFieldPresentation.presentations(for: secrets, pluginID: pluginID)
        self.mode = mode
    }

    public init(
        pluginID: String,
        fields: [PluginCredentialFieldPresentation],
        mode: PluginCredentialCollectionMode
    ) {
        self.pluginID = pluginID
        self.fields = fields
        self.mode = mode
    }

    public var secrets: [PluginSecretDescriptor] {
        fields.map(\.descriptor)
    }

    enum CodingKeys: String, CodingKey {
        case pluginID = "plugin_id"
        case fields
        case secrets
        case mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginID = try container.decode(String.self, forKey: .pluginID)
        mode = try container.decodeIfPresent(PluginCredentialCollectionMode.self, forKey: .mode)
            ?? .requireMissing
        if let fields = try container.decodeIfPresent(
            [PluginCredentialFieldPresentation].self,
            forKey: .fields
        ) {
            self.fields = fields
        } else {
            let legacy = try container.decode([PluginSecretDescriptor].self, forKey: .secrets)
            self.fields = legacy.map {
                PluginCredentialFieldPresentation(
                    id: $0.id,
                    label: $0.label,
                    kind: $0.kind,
                    hasStoredValue: false
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encode(fields, forKey: .fields)
        try container.encode(mode, forKey: .mode)
    }
}
