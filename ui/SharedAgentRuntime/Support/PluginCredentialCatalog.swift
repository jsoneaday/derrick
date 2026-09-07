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
        let json = manifests.first(where: { $0.pluginID == pluginID })?.manifestJSON
        return PluginSecretField.resolvedDescriptors(pluginID: pluginID, fromManifestJSON: json)
    }

    static func connectorPluginIDs(repository: DBRepository) async -> [String] {
        let manifests = (try? await repository.listLatestPluginFactoryManifests()) ?? []
        return manifests.compactMap { row in
            AgentPluginManifest.isConnector(manifestJSON: row.manifestJSON) ? row.pluginID : nil
        }
        .sorted()
    }

    static func pluginsWithSecrets(repository: DBRepository) async -> [PluginCredentialGroup] {
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

struct PluginCredentialGroup: Equatable, Identifiable {
    let pluginID: String
    let isConnector: Bool
    let secrets: [PluginSecretDescriptor]

    var id: String { pluginID }

    var displayName: String {
        pluginID
            .split(separator: "-")
            .map { part in
                let lower = part.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
