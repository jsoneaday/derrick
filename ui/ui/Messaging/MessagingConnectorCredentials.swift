import DBRepository
import Foundation
import Plugin
import Structure

/// Credential prompt when a messaging connector is opened.
@MainActor
enum MessagingConnectorCredentials {
    enum EnsureResult: Equatable {
        case ok
        case cancelled
    }

    static func ensureIfNeeded(pluginID: String, repository: DBRepository) async -> EnsureResult {
        let secrets = await ConnectorCredentialService.secretDescriptors(
            pluginID: pluginID,
            repository: repository
        )
        migrateLegacyCredentialsIfNeeded(pluginID: pluginID, secrets: secrets)
        guard !secrets.isEmpty else { return .ok }

        let missing = PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: secrets)
        guard !missing.isEmpty else { return .ok }

        switch await ConnectorCredentialService.present(
            pluginID: pluginID,
            secrets: secrets,
            mode: .requireMissing
        ) {
        case .ok:
            return PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: secrets).isEmpty
                ? .ok
                : .cancelled
        case .cancelled:
            return .cancelled
        }
    }

    private static func migrateLegacyCredentialsIfNeeded(
        pluginID: String,
        secrets: [PluginSecretDescriptor]
    ) {
        guard pluginID == "slack-connector" else { return }
        PluginSecretKeychain.migrateStoredFields(
            from: "slack-connection",
            to: pluginID,
            fields: secrets
        )
    }
}
