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
    }

    public func pollInbox(repository: DBRepository) async throws -> [MessagingPersistResult] {
        let threads = try await repository.listMessagingThreads(pluginID: pluginID)
        guard !threads.isEmpty else { return [] }
        let connector = try await repository.listMessagingConnectors()
            .first(where: { $0.pluginID == pluginID })

        var inserted: [MessagingPersistResult] = []
        for thread in threads {
            inserted.append(
                contentsOf: try await pollConversation(
                    thread: thread,
                    parentVendorMessageID: nil,
                    repository: repository,
                    connector: connector
                )
            )
        }
        return inserted
    }

    public func pollConversation(
        vendorThreadID: String,
        parentVendorMessageID: String?,
        repository: DBRepository
    ) async throws -> [MessagingPersistResult] {
        let threads = try await repository.listMessagingThreads(pluginID: pluginID)
        guard let thread = threads.first(where: { $0.vendorThreadID == vendorThreadID }) else {
            return []
        }
        let connector = try await repository.listMessagingConnectors()
            .first(where: { $0.pluginID == pluginID })
        return try await pollConversation(
            thread: thread,
            parentVendorMessageID: parentVendorMessageID,
            repository: repository,
            connector: connector
        )
    }

    private func pollConversation(
        thread: MessagingThreadDTO,
        parentVendorMessageID: String?,
        repository: DBRepository,
        connector: MessagingConnectorDTO?
    ) async throws -> [MessagingPersistResult] {
        var params: [String: PluginJSON] = [
            "vendor_thread_id": .string(thread.vendorThreadID),
        ]
        if let parent = parentVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parent.isEmpty {
            params["parent_vendor_message_id"] = .string(parent)
            params["thread_ts"] = .string(parent)
        }
        let filter: MessagingMessageListFilter = {
            if let parent = parentVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !parent.isEmpty {
                return .replyThread(parentVendorMessageID: parent)
            }
            return .channelRoots
        }()
        if let cursor = try await pollCursor(
            for: thread,
            filter: filter,
            repository: repository
        ) {
            params["since"] = .string(cursor)
            params["oldest"] = .string(cursor)
        } else if parentVendorMessageID == nil, let baseline = pollBaseline(
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
        try Self.throwIfReplyThreadBlocked(
            result: result,
            parentVendorMessageID: parentVendorMessageID
        )
        if result.messages.isEmpty,
           result.reportsVendorFailure,
           let detail = result.terminalDetail {
            throw ConnectorMessagingError.pluginFailed(detail)
        }
        return try await ConnectorMessagingPersistence.apply(
            result,
            pluginID: pluginID,
            repository: repository,
            pollVendorThreadID: thread.vendorThreadID
        )
    }

    private static func throwIfReplyThreadBlocked(
        result: ConnectorMessagingResult,
        parentVendorMessageID: String?
    ) throws {
        let parent = parentVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !parent.isEmpty else { return }
        guard let detail = result.terminalDetail else { return }
        if let mapped = ConnectorReplyThreadAccessMessage.userFacing(fromVendorDetail: detail) {
            throw ConnectorMessagingError.pluginFailed(mapped)
        }
    }

    private func pollCursor(
        for thread: MessagingThreadDTO,
        filter: MessagingMessageListFilter,
        repository: DBRepository
    ) async throws -> String? {
        let messages = try await repository.listMessagingMessages(
            threadID: thread.id,
            limit: MessagingViewport.maxVisibleMessages,
            filter: filter
        )
        guard let latestInbound = messages.last(where: { $0.direction == .inbound }) else {
            return nil
        }
        if let vendorMessageID = latestInbound.vendorMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !vendorMessageID.isEmpty {
            return vendorMessageID
        }
        return ConnectorPollCursor.unixSeconds(latestInbound.createdAt)
    }

    /// When no inbound cursor exists yet, only fetch vendor messages after the user opened the connector.
    private func pollBaseline(
        thread: MessagingThreadDTO,
        connector: MessagingConnectorDTO?
    ) -> String? {
        let anchor = connector?.listeningSince ?? thread.createdAt
        return ConnectorPollCursor.unixSeconds(anchor)
    }

    public func sendMessage(
        vendorThreadID: String,
        text: String,
        threadID: String,
        parentVendorMessageID: String? = nil,
        repository: DBRepository
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var params: [String: PluginJSON] = [
            "vendor_thread_id": .string(vendorThreadID),
            "text": .string(trimmed),
        ]
        if let parent = parentVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parent.isEmpty {
            params["parent_vendor_message_id"] = .string(parent)
            params["thread_ts"] = .string(parent)
        }
        let result = try await invoker.invoke(
            pluginID: pluginID,
            operation: .sendMessage,
            params: params
        )
        let sent = try ConnectorMessagingParser.requireSentMessage(result)
        let outbound = MessagingMessageDTO(
            threadID: threadID,
            vendorMessageID: sent.vendorMessageID,
            direction: .outbound,
            sender: "derrick",
            body: trimmed,
            createdAt: sent.createdAt,
            parentVendorMessageID: parentVendorMessageID
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
