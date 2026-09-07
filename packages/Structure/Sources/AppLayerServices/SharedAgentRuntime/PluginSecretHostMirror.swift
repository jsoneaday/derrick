import Foundation

/// Ensures daemon-owned connector invokes can read secrets from Keychain.
public enum PluginSecretHostMirror: Sendable {
    public static func syncDevelopmentSecretsToKeychain(
        pluginID: String,
        fields: [PluginSecretDescriptor]
    ) {
        do {
            try syncDevelopmentSecretsToKeychainOrThrow(pluginID: pluginID, fields: fields)
        } catch {
            fputs(
                "[plugin-secrets] could not copy development secrets to Keychain for \(pluginID): \(error.localizedDescription)\n",
                stderr
            )
        }
    }

    public static func syncDevelopmentSecretsToKeychainOrThrow(
        pluginID: String,
        fields: [PluginSecretDescriptor]
    ) throws {
        guard PluginSecretDevelopmentSource.isEnabled() else { return }
        for field in fields {
            guard let value = PluginSecretDevelopmentSource.resolve(
                pluginID: pluginID,
                fieldID: field.id
            ) else {
                continue
            }
            if !PluginSecretKeychain.hasKeychainValue(pluginID: pluginID, fieldID: field.id) {
                try PluginSecretKeychain.save(pluginID: pluginID, fieldID: field.id, value: value)
            }
        }
    }
}
