import DBRepository
import Foundation
import Plugin
import ServiceContracts

/// Vendor-agnostic connector ingress through `plugin.invoke`.
final class PluginMessagingIngressAdapter: MessagingIngressAdapter, @unchecked Sendable {
    let pluginID: String
    private let invoker: ConnectorPluginInvoker

    init(pluginID: String, invoker: ConnectorPluginInvoker? = nil) {
        self.pluginID = pluginID
        self.invoker = invoker ?? ConnectorPluginInvoker { pluginID, input in
            try await PluginInvokeBridge.invoke(pluginID: pluginID, input: input)
        }
    }

    func hasCredentials() -> Bool {
        for fieldID in ["bot_token", "token", "api_key"] {
            if PluginSecretKeychain.hasStoredValue(pluginID: pluginID, fieldID: fieldID) {
                return true
            }
        }
        return false
    }

    func syncThreads(repository: DBRepository) async throws {
        let result = try await invoker.invoke(pluginID: pluginID, operation: .syncThreads)
        _ = try await ConnectorMessagingPersistence.apply(result, pluginID: pluginID, repository: repository)
    }

    func pollInbox(repository: DBRepository) async throws -> [MessagingPersistResult] {
        let result = try await invoker.invoke(pluginID: pluginID, operation: .pollInbox)
        return try await ConnectorMessagingPersistence.apply(result, pluginID: pluginID, repository: repository)
    }

    func sendMessage(
        vendorThreadID: String,
        text: String,
        threadID: String,
        repository: DBRepository
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = try await invoker.invoke(
            pluginID: pluginID,
            operation: .sendMessage,
            params: [
                "vendor_thread_id": .string(vendorThreadID),
                "text": .string(trimmed),
            ]
        )
        let sent = try ConnectorMessagingParser.requireSentMessage(result)
        let outbound = MessagingMessageDTO(
            threadID: threadID,
            vendorMessageID: sent.vendorMessageID,
            direction: .outbound,
            sender: "derrick",
            body: trimmed,
            createdAt: sent.createdAt
        )
        _ = try await repository.insertMessagingMessage(outbound, incrementUnread: false)
    }
}
