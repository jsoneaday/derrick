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
        session: MessagingSessionStore,
        generation: Int? = nil
    ) async {
        store.setConnectorSyncing(true)
        defer {
            if generation == nil || store.connectorCommandID == generation {
                store.setConnectorSyncing(false)
            }
        }
        do {
            try await client.bootstrap(pluginID: pluginID)
            guard generation == nil || store.connectorCommandID == generation else { return }
            let shouldAutoOpen = session.selectedThreadID == nil && store.hostUIRoot.opensFirstConversation
            await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: shouldAutoOpen)
            if session.selectedThreadID == nil, store.hostUIRoot.opensFirstConversation,
               let threadID = session.threads.first?.id {
                await session.selectThread(id: threadID)
            }
            if let threadID = session.selectedThreadID {
                await session.reloadMessagesForThread(id: threadID)
            }
            session.setLastError(nil)
        } catch {
            guard generation == nil || store.connectorCommandID == generation else { return }
            let raw = error.localizedDescription
            if ConnectorMessagingClientError.isTimeout(error) {
                return
            }
            session.setLastError(raw)
            Task {
                await ServiceLogRecorder.shared.record(
                    service: "messaging",
                    level: .error,
                    code: "bootstrap_failed",
                    message: "Messaging bootstrap failed pluginID=\(pluginID): \(raw)",
                    detailJSON: Self.detailJSON(
                        pluginID: pluginID,
                        error: raw
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
        parentVendorMessageID: String? = nil,
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
            text: trimmed,
            parentVendorMessageID: parentVendorMessageID
        )
        if let parent = parentVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parent.isEmpty {
            try? await client.pollInbox(
                pluginID: pluginID,
                vendorThreadID: thread.vendorThreadID,
                parentVendorMessageID: parent
            )
        }
        await session.reloadMessagesForThread(id: thread.id)
        await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
        await store.catalog.refreshBadges()
    }

    func pollConversation(
        pluginID: String,
        vendorThreadID: String,
        parentVendorMessageID: String?,
        threadID: String,
        session: MessagingSessionStore
    ) async throws {
        try await client.pollInbox(
            pluginID: pluginID,
            vendorThreadID: vendorThreadID,
            parentVendorMessageID: parentVendorMessageID
        )
        await session.reloadMessagesForThread(id: threadID)
    }
}
