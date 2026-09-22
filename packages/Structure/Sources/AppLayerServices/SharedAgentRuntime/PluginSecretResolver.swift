import Foundation

/// Resolves declared plugin secrets from Keychain, with a development `.env` escape hatch.
public enum PluginSecretResolver: Sendable {
    /// Field ids the host and daemon accept as an HTTP call credential.
    /// Create-time auth preference may store `api_token` when docs look OAuth-only.
    /// Older call sites looked only for `bot_token`.
    public static let callCredentialFieldIDs: [String] = [
        "bot_token",
        "token",
        "api_key",
        "api_token",
        "access_token",
    ]

    public static func resolve(pluginID: String, fieldID: String) -> String? {
        if let development = PluginSecretDevelopmentSource.resolve(
            pluginID: pluginID,
            fieldID: fieldID
        ) {
            return development
        }
        guard let value = try? PluginSecretKeychain.loadFromKeychain(
            pluginID: pluginID,
            fieldID: fieldID
        ) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// First non-empty call credential under any known field id.
    public static func resolveCallCredential(pluginID: String) -> String? {
        for fieldID in callCredentialFieldIDs {
            if let value = resolve(pluginID: pluginID, fieldID: fieldID) {
                return value
            }
        }
        return nil
    }

    public static func hasCallCredential(pluginID: String) -> Bool {
        resolveCallCredential(pluginID: pluginID) != nil
    }
}
