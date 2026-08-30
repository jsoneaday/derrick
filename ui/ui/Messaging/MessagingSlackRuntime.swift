import DBRepository
import Foundation
import ServiceContracts

/// Live Slack sync for the `slack-connection` connector.
@MainActor
final class MessagingSlackRuntime {
    static let pluginID = "slack-connection"
    private static let pollIntervalNanoseconds: UInt64 = 4_000_000_000

    private var pollTask: Task<Void, Never>?
    private var botUserID: String?

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func resumePolling(store: MessagingStore, repository: DBRepository) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak store] in
            while !Task.isCancelled {
                guard let store else { return }
                await poll(store: store, repository: repository)
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    func bootstrap(store: MessagingStore, repository: DBRepository, session: MessagingSessionStore) async {
        store.isSlackSyncing = true
        defer { store.isSlackSyncing = false }
        do {
            try await syncChannels(repository: repository)
            try await importRecentMessages(repository: repository, store: store)
            await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: true)
            if let threadID = session.selectedThreadID {
                await session.reloadMessagesForThread(id: threadID)
            }
        } catch {
            session.setLastError(error.localizedDescription)
        }
    }

    func send(
        text: String,
        thread: MessagingThreadDTO,
        repository: DBRepository,
        store: MessagingStore,
        session: MessagingSessionStore
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let token = try requireToken()
        let api = SlackWebAPI(token: token)
        if botUserID == nil {
            botUserID = try await api.authTest().userID
        }
        let sent = try await api.postMessage(channelID: thread.vendorThreadID, text: trimmed)
        let outbound = MessagingMessageDTO(
            threadID: thread.id,
            vendorMessageID: sent.timestamp,
            direction: .outbound,
            sender: "derrick",
            body: trimmed,
            createdAt: sent.createdAt
        )
        _ = try await repository.insertMessagingMessage(outbound, incrementUnread: false)
        await session.reloadMessagesForThread(id: thread.id)
        await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
        await store.catalog.refreshBadges()
    }

    private func poll(store: MessagingStore, repository: DBRepository) async {
        guard store.selectedPluginID == Self.pluginID else { return }
        do {
            try await importRecentMessages(repository: repository, store: store)
            if let threadID = store.selectedThreadID {
                await store.session.reloadMessagesForThread(id: threadID)
            }
            await store.session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
            await store.catalog.refreshBadges()
        } catch {
            store.session.setLastError(error.localizedDescription)
        }
    }

    private func syncChannels(repository: DBRepository) async throws {
        let token = try requireToken()
        let api = SlackWebAPI(token: token)
        if botUserID == nil {
            botUserID = try await api.authTest().userID
        }
        let channels = try await api.listMemberChannels()
        for channel in channels {
            let thread = MessagingThreadDTO(
                pluginID: Self.pluginID,
                vendorThreadID: channel.id,
                title: "#\(channel.name)"
            )
            try await repository.upsertMessagingThread(thread)
        }
    }

    private func importRecentMessages(repository: DBRepository, store: MessagingStore) async throws {
        let token = try requireToken()
        let api = SlackWebAPI(token: token)
        if botUserID == nil {
            botUserID = try await api.authTest().userID
        }
        let threads = try await repository.listMessagingThreads(pluginID: Self.pluginID)
        for thread in threads {
            let messages = try await api.fetchHistory(channelID: thread.vendorThreadID, limit: 50)
            for message in messages.reversed() {
                let direction: MessagingMessageDirection =
                    message.botID != nil || message.userID == botUserID ? .outbound : .inbound
                let sender = direction == .outbound ? "derrick" : (message.userID ?? "Slack user")
                let record = MessagingInboundRecord(
                    pluginID: Self.pluginID,
                    vendorThreadID: thread.vendorThreadID,
                    threadTitle: thread.title,
                    vendorMessageID: message.timestamp,
                    sender: sender,
                    body: message.text,
                    createdAt: message.createdAt,
                    countAsUnread: direction == .inbound
                )
                if direction == .inbound {
                    let result = try await repository.persistMessagingInbound(record)
                    if result.inserted {
                        await store.session.applyPersistedInbound(result)
                    }
                } else {
                    let outbound = MessagingMessageDTO(
                        threadID: thread.id,
                        vendorMessageID: message.timestamp,
                        direction: .outbound,
                        sender: sender,
                        body: message.text,
                        createdAt: message.createdAt
                    )
                    _ = try await repository.insertMessagingMessage(outbound, incrementUnread: false)
                }
            }
        }
    }

    private func requireToken() throws -> String {
        guard let token = PluginSecretResolver.resolve(
            pluginID: Self.pluginID,
            fieldID: "bot_token"
        ), !token.isEmpty else {
            throw SlackWebAPI.APIError.missingToken
        }
        return token
    }
}
