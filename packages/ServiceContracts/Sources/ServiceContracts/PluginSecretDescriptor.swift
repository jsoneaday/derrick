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

public struct PluginCredentialPromptPayload: Codable, Sendable, Hashable {
    public let pluginID: String
    public let secrets: [PluginSecretDescriptor]

    public init(pluginID: String, secrets: [PluginSecretDescriptor]) {
        self.pluginID = pluginID
        self.secrets = secrets
    }

    enum CodingKeys: String, CodingKey {
        case pluginID = "plugin_id"
        case secrets
    }
}
