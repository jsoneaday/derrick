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
    private var sendOnlyConnectors: Set<String> = []
    private var pollInboxConnectors: Set<String> = []
    private var syncThreadsConnectors: Set<String> = []

    func configure(repository: DBRepository) async {
        self.repository = repository
        await reloadFromFactory()
    }

    func reloadFromFactory(preservingPluginIDs: Set<String> = []) async {
        guard let repository else { return }
        lastError = nil
        do {
            let manifests = try await repository.listLatestPluginFactoryManifests()
            var connectorIDs: [String] = []
            var sendOnly: Set<String> = []
            var pollInbox: Set<String> = []
            var syncThreads: Set<String> = []
            for row in manifests {
                guard AgentPluginManifest.isConnector(manifestJSON: row.manifestJSON) else { continue }
                guard PluginFactoryCreateInput.ConnectorVendor.isEnabledMessagingPluginID(row.pluginID) else {
                    continue
                }
                connectorIDs.append(row.pluginID)
                if PluginFactoryValidationExpectations.isSendOnlyConnector(manifestJSON: row.manifestJSON) {
                    sendOnly.insert(row.pluginID)
                }
                if PluginFactoryValidationExpectations.supportsPollInbox(manifestJSON: row.manifestJSON) {
                    pollInbox.insert(row.pluginID)
                }
                if PluginFactoryValidationExpectations.supportsSyncThreads(manifestJSON: row.manifestJSON) {
                    syncThreads.insert(row.pluginID)
                }
                try await repository.upsertMessagingConnector(
                    MessagingConnectorDTO(
                        pluginID: row.pluginID,
                        displayName: Self.displayName(pluginID: row.pluginID)
                    )
                )
            }
            for pluginID in preservingPluginIDs where !connectorIDs.contains(pluginID) {
                guard PluginFactoryCreateInput.ConnectorVendor.isEnabledMessagingPluginID(pluginID) else {
                    continue
                }
                connectorIDs.append(pluginID)
                try await repository.upsertMessagingConnector(
                    MessagingConnectorDTO(
                        pluginID: pluginID,
                        displayName: Self.displayName(pluginID: pluginID)
                    )
                )
            }
            try await repository.pruneMessagingConnectors(keeping: Set(connectorIDs))
            sendOnlyConnectors = sendOnly
            pollInboxConnectors = pollInbox
            syncThreadsConnectors = syncThreads
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

    func isSendOnlyConnector(pluginID: String) -> Bool {
        sendOnlyConnectors.contains(pluginID)
    }

    func supportsPollInbox(pluginID: String) -> Bool {
        pollInboxConnectors.contains(pluginID)
    }

    func supportsSyncThreads(pluginID: String) -> Bool {
        syncThreadsConnectors.contains(pluginID)
    }

    func supportsThreadDiscovery(pluginID: String) -> Bool {
        supportsSyncThreads(pluginID: pluginID)
    }

    static func displayName(pluginID: String) -> String {
        pluginID
            .split(separator: "-")
            .map { part in
                let lower = part.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
