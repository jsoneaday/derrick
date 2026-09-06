import DBRepository
import Foundation
import Plugin
import Structure

/// Vendor-agnostic connector ingress through `plugin.invoke`.
public final class PluginMessagingIngressAdapter: MessagingIngressAdapter, @unchecked Sendable {
    public let pluginID: String
    private let invoker: ConnectorPluginInvoker

    public init(pluginID: String, invoker: ConnectorPluginInvoker? = nil) {
        self.pluginID = pluginID
        self.invoker = invoker ?? ConnectorPluginInvoker { pluginID, input in
            try await PluginInvokeBridge.invoke(pluginID: pluginID, input: input)
        }
    }

    public func hasCredentials() -> Bool {
        for fieldID in ["bot_token", "token", "api_key"] {
            if PluginSecretResolver.resolve(pluginID: pluginID, fieldID: fieldID) != nil {
                return true
            }
        }
        return false
    }

    public func syncThreads(repository: DBRepository) async throws {
        let result = try await invoker.invoke(pluginID: pluginID, operation: .syncThreads)
        if result.threads.isEmpty, let detail = result.terminalDetail {
            throw ConnectorMessagingError.pluginFailed(detail)
        }
        _ = try await ConnectorMessagingPersistence.apply(
            result,
            pluginID: pluginID,
            repository: repository,
            replaceThreadCatalog: true
        )
        if result.threads.isEmpty {
            let persisted = try await repository.listMessagingThreads(pluginID: pluginID)
            if persisted.isEmpty {
                throw ConnectorMessagingError.pluginFailed(
                    "No conversations were returned. Check the bot token and invite the bot to channels."
                )
            }
        }
    }

    public func pollInbox(repository: DBRepository) async throws -> [MessagingPersistResult] {
        let threads = try await repository.listMessagingThreads(pluginID: pluginID)
        guard !threads.isEmpty else { return [] }
        let connector = try await repository.listMessagingConnectors()
            .first(where: { $0.pluginID == pluginID })

        var inserted: [MessagingPersistResult] = []
        for thread in threads {
            var params: [String: PluginJSON] = [
                "vendor_thread_id": .string(thread.vendorThreadID),
            ]
            if let cursor = try await pollCursor(for: thread, repository: repository) {
                params["since"] = .string(cursor)
                params["oldest"] = .string(cursor)
            } else if let baseline = pollBaseline(
                thread: thread,
                connector: connector
            ) {
                params["since"] = .string(baseline)
                params["oldest"] = .string(baseline)
            }
            let result = try await invoker.invoke(
                pluginID: pluginID,
                operation: .pollInbox,
                params: params
            )
            inserted.append(
                contentsOf: try await ConnectorMessagingPersistence.apply(
                    result,
                    pluginID: pluginID,
                    repository: repository,
                    pollVendorThreadID: thread.vendorThreadID
                )
            )
        }
        return inserted
    }

    private func pollCursor(for thread: MessagingThreadDTO, repository: DBRepository) async throws -> String? {
        let messages = try await repository.listMessagingMessages(
            threadID: thread.id,
            limit: MessagingViewport.maxVisibleMessages
        )
        guard let latestInbound = messages.last(where: { $0.direction == .inbound }) else {
            return nil
        }
        if let vendorMessageID = latestInbound.vendorMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !vendorMessageID.isEmpty {
            return vendorMessageID
        }
        return String(latestInbound.createdAt.timeIntervalSince1970)
    }

    /// When no inbound cursor exists yet, only fetch vendor messages after the user opened the connector.
    private func pollBaseline(
        thread: MessagingThreadDTO,
        connector: MessagingConnectorDTO?
    ) -> String? {
        let anchor = connector?.listeningSince ?? thread.createdAt
        return String(anchor.timeIntervalSince1970)
    }

    public func sendMessage(
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

    public func bootstrap(repository: DBRepository) async throws {
        let manifestJSON = try await repository.listLatestPluginFactoryManifests()
            .first(where: { $0.pluginID == pluginID })?
            .manifestJSON ?? ""
        if PluginFactoryValidationExpectations.supportsSyncThreads(manifestJSON: manifestJSON) {
            try await syncThreads(repository: repository)
        }
        // Do not poll on bootstrap — that would import vendor history into SQLite.
        // Background ingress polls incrementally using listening_since / inbound cursors.
    }
}
