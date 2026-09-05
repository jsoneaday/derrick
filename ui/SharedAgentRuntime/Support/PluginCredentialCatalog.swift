import DBRepository
import Foundation
import Plugin
import Structure

enum PluginCredentialCatalog {
    static func secretDescriptors(
        pluginID: String,
        repository: DBRepository
    ) async -> [PluginSecretDescriptor] {
        let manifests = (try? await repository.listLatestPluginFactoryManifests()) ?? []
        guard let row = manifests.first(where: { $0.pluginID == pluginID }) else { return [] }
        return PluginSecretField.fields(fromManifestJSON: Data(row.manifestJSON.utf8))
            .map(\.descriptor)
    }

    static func connectorPluginIDs(repository: DBRepository) async -> [String] {
        let manifests = (try? await repository.listLatestPluginFactoryManifests()) ?? []
        return manifests.compactMap { row in
            AgentPluginManifest.isConnector(manifestJSON: row.manifestJSON) ? row.pluginID : nil
        }
        .sorted()
    }
}
