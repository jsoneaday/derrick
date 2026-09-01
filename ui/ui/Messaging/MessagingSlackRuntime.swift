import DBRepository
import Foundation
import ServiceContracts

/// UI-side Slack send + channel bootstrap. Receive runs in derrickd (`MessagingIngressService`).
@MainActor
final class MessagingSlackRuntime {
    static let pluginID = "slack-connection"

    func bootstrap(store: MessagingStore, repository: DBRepository, session: MessagingSessionStore) async {
        store.isSlackSyncing = true
        defer { store.isSlackSyncing = false }
        do {
            try await syncChannels(repository: repository)
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
        _ = try await api.authTest()
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

    private func syncChannels(repository: DBRepository) async throws {
        let token = try requireToken()
        let api = SlackWebAPI(token: token)
        _ = try await api.authTest()
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

    private func requireToken() throws -> String {
        guard let token = PluginSecretResolver.resolve(
            pluginID: Self.pluginID,
            fieldID: "bot_token"
        ), !token.isEmpty else {
            if PluginSecretResolver.usesDotenvOnly {
                throw NSError(
                    domain: "MessagingSlackRuntime",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: PluginSecretResolver.missingDotenvMessage(
                            pluginID: Self.pluginID,
                            fieldID: "bot_token"
                        ),
                    ]
                )
            }
            throw SlackWebAPI.APIError.missingToken
        }
        return token
    }
}
