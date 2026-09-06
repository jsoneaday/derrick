import DBRepository
import Foundation
import Structure

/// UI-side connector bootstrap and send through the daemon command service.
@MainActor
final class ConnectorMessagingRuntime {
    private let client: ConnectorMessagingClient

    init(client: ConnectorMessagingClient = .shared) {
        self.client = client
    }

    func bootstrap(
        pluginID: String,
        store: MessagingStore,
        session: MessagingSessionStore
    ) async {
        store.setConnectorSyncing(true)
        defer { store.setConnectorSyncing(false) }
        do {
            try await client.bootstrap(pluginID: pluginID)
            await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
            if store.supportsThreadDiscovery, session.threads.isEmpty {
                throw ConnectorMessagingError.pluginFailed(
                    "No conversations were returned. Check the bot token and invite the bot to Slack channels, then tap Refresh list."
                )
            }
            if store.supportsThreadDiscovery {
                if session.threads.count == 1, let threadID = session.threads.first?.id {
                    await session.selectThread(id: threadID)
                }
            } else if let threadID = session.threads.first?.id {
                await session.selectThread(id: threadID)
            }
            if let threadID = session.selectedThreadID {
                await session.reloadMessagesForThread(id: threadID)
            }
            session.setLastError(nil)
        } catch {
            let detail = error.localizedDescription
            session.setLastError(detail)
            Task {
                await ServiceLogRecorder.shared.record(
                    service: "messaging",
                    level: .error,
                    code: "bootstrap_failed",
                    message: "Messaging bootstrap failed pluginID=\(pluginID): \(detail)",
                    detailJSON: Self.detailJSON(
                        pluginID: pluginID,
                        error: detail
                    )
                )
            }
        }
    }

    private static func detailJSON(pluginID: String, error: String) -> String? {
        let payload = ["pluginID": pluginID, "error": error]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func send(
        pluginID: String,
        text: String,
        thread: MessagingThreadDTO,
        repository: DBRepository,
        store: MessagingStore,
        session: MessagingSessionStore
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await client.send(
            pluginID: pluginID,
            vendorThreadID: thread.vendorThreadID,
            threadID: thread.id,
            text: trimmed
        )
        await session.reloadMessagesForThread(id: thread.id)
        await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
        await store.catalog.refreshBadges()
    }
}
