import DBRepository
import Foundation
import ServiceContracts

/// Slack ingress via host-owned Web API polling (Socket Mode can replace this later).
final class SlackMessagingIngressAdapter: MessagingIngressAdapter, @unchecked Sendable {
    static let pluginID = "slack-connection"
    private static let botTokenFieldID = "bot_token"

    var pluginID: String { Self.pluginID }

    func hasCredentials() -> Bool {
        guard let token = PluginSecretResolver.resolve(
            pluginID: pluginID,
            fieldID: Self.botTokenFieldID
        ) else {
            return false
        }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func syncThreads(repository: DBRepository) async throws {
        let api = try makeAPI()
        _ = try await api.authTest()
        let channels = try await api.listMemberChannels()
        for channel in channels {
            let thread = MessagingThreadDTO(
                pluginID: pluginID,
                vendorThreadID: channel.id,
                title: "#\(channel.name)"
            )
            try await repository.upsertMessagingThread(thread)
        }
    }

    func pollInbox(repository: DBRepository) async throws -> [MessagingPersistResult] {
        let api = try makeAPI()
        let botID = try await api.authTest().userID
        let threads = try await repository.listMessagingThreads(pluginID: pluginID)
        var inserted: [MessagingPersistResult] = []
        for thread in threads {
            let messages = try await api.fetchHistory(channelID: thread.vendorThreadID, limit: 50)
            for message in messages.reversed() {
                let direction: MessagingMessageDirection =
                    message.botID != nil || message.userID == botID ? .outbound : .inbound
                if direction == .inbound {
                    let record = MessagingInboundRecord(
                        pluginID: pluginID,
                        vendorThreadID: thread.vendorThreadID,
                        threadTitle: thread.title,
                        vendorMessageID: message.timestamp,
                        sender: message.userID ?? "Slack user",
                        body: message.text,
                        createdAt: message.createdAt,
                        countAsUnread: true
                    )
                    let result = try await repository.persistMessagingInbound(record)
                    if result.inserted {
                        inserted.append(result)
                    }
                } else {
                    let outbound = MessagingMessageDTO(
                        threadID: thread.id,
                        vendorMessageID: message.timestamp,
                        direction: .outbound,
                        sender: "derrick",
                        body: message.text,
                        createdAt: message.createdAt
                    )
                    _ = try await repository.insertMessagingMessage(
                        outbound,
                        incrementUnread: false
                    )
                }
            }
        }
        return inserted
    }

    private func makeAPI() throws -> SlackWebAPI {
        guard let token = PluginSecretResolver.resolve(
            pluginID: pluginID,
            fieldID: Self.botTokenFieldID
        ), !token.isEmpty else {
            throw SlackWebAPI.APIError.missingToken
        }
        return SlackWebAPI(token: token)
    }
}
