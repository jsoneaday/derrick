import Combine
import DBRepository
import Foundation
import Plugin
import Structure

/// Connector catalog only. Does not own open tabs or the message window.
@MainActor
final class MessagingCatalogStore: ObservableObject {
    @Published private(set) var connectors: [MessagingConnectorDTO] = []
    @Published private(set) var lastError: String?

    private var repository: DBRepository?

    func configure(repository: DBRepository) async {
        self.repository = repository
        await reloadFromFactory()
    }

    func reloadFromFactory() async {
        guard let repository else { return }
        lastError = nil
        do {
            let manifests = try await repository.listLatestPluginFactoryManifests()
            var connectorIDs: [String] = []
            for row in manifests {
                guard AgentPluginManifest.isConnector(manifestJSON: row.manifestJSON) else { continue }
                connectorIDs.append(row.pluginID)
                try await repository.upsertMessagingConnector(
                    MessagingConnectorDTO(
                        pluginID: row.pluginID,
                        displayName: Self.displayName(pluginID: row.pluginID)
                    )
                )
            }
            try await repository.pruneMessagingConnectors(keeping: Set(connectorIDs))
            let stored = try await repository.listMessagingConnectors()
            let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.pluginID, $0) })
            connectors = connectorIDs.compactMap { storedByID[$0] }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshBadges() async {
        guard let repository else { return }
        do {
            let stored = try await repository.listMessagingConnectors()
            let visibleIDs = Set(connectors.map(\.pluginID))
            connectors = stored.filter { visibleIDs.contains($0.pluginID) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unreadTotal(for pluginID: String) -> Int {
        connectors.first { $0.pluginID == pluginID }?.unreadCount ?? 0
    }

    func contains(pluginID: String) -> Bool {
        connectors.contains { $0.pluginID == pluginID }
    }

    private static func displayName(pluginID: String) -> String {
        pluginID
            .split(separator: "-")
            .map { part in
                let lower = part.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
