import Foundation

/// Resolves declared plugin secrets from Keychain only.
public enum PluginSecretResolver: Sendable {
    public static func resolve(pluginID: String, fieldID: String) -> String? {
        guard let value = try? PluginSecretKeychain.loadFromKeychain(
            pluginID: pluginID,
            fieldID: fieldID
        ) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
