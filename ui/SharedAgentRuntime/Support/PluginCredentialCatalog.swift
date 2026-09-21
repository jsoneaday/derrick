import Foundation
import Plugin
import Structure

enum PluginCredentialCatalog {
    static func secretDescriptors(
        pluginID: String,
        repository: any PluginFactoryManifestCatalog
    ) async -> [PluginSecretDescriptor] {
        let manifests = (try? await repository.listLatestPluginFactoryManifests()) ?? []
        let json = manifests.first(where: { $0.pluginID == pluginID })?.manifestJSON
        return PluginSecretField.resolvedDescriptors(pluginID: pluginID, fromManifestJSON: json)
    }

    static func connectorPluginIDs(repository: any PluginFactoryManifestCatalog) async -> [String] {
        let manifests = (try? await repository.listLatestPluginFactoryManifests()) ?? []
        return manifests.compactMap { row in
            AgentPluginManifest.isConnector(manifestJSON: row.manifestJSON) ? row.pluginID : nil
        }
        .sorted()
    }

    static func pluginsWithSecrets(repository: any PluginFactoryManifestCatalog) async -> [PluginCredentialGroup] {
        let manifests = (try? await repository.listLatestPluginFactoryManifests()) ?? []
        return manifests.compactMap { row -> PluginCredentialGroup? in
            let secrets = PluginSecretField.resolvedDescriptors(
                pluginID: row.pluginID,
                fromManifestJSON: row.manifestJSON
            )
            guard !secrets.isEmpty else { return nil }
            return PluginCredentialGroup(
                pluginID: row.pluginID,
                isConnector: AgentPluginManifest.isConnector(manifestJSON: row.manifestJSON),
                secrets: secrets
            )
        }
        .sorted { lhs, rhs in
            if lhs.isConnector != rhs.isConnector {
                return lhs.isConnector && !rhs.isConnector
            }
            return lhs.pluginID < rhs.pluginID
        }
    }
}
