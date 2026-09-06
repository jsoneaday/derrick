import Foundation

/// Ensures daemon-owned connector invokes can read secrets from Keychain.
public enum PluginSecretHostMirror: Sendable {
    public static func syncDevelopmentSecretsToKeychain(
        pluginID: String,
        fields: [PluginSecretDescriptor]
    ) {
        guard PluginSecretDevelopmentSource.isEnabled() else { return }
        for field in fields {
            guard let value = PluginSecretDevelopmentSource.resolve(
                pluginID: pluginID,
                fieldID: field.id
            ) else {
                continue
            }
            if (try? PluginSecretKeychain.loadFromKeychain(pluginID: pluginID, fieldID: field.id)) == nil {
                try? PluginSecretKeychain.save(pluginID: pluginID, fieldID: field.id, value: value)
            }
        }
    }
}
