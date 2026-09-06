import Foundation

/// Resolves declared plugin secrets from Keychain, with a development `.env` escape hatch.
public enum PluginSecretResolver: Sendable {
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
}
