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
        PluginSecretResolver.hasCallCredential(pluginID: pluginID)
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

    public func pollInbox(
        repository: DBRepository,
        preferredVendorThreadID: String? = nil,
        preferredParentVendorMessageID: String? = nil,
        maxChannelPolls: Int? = nil,
        channelOffset: Int = 0
    ) async throws -> [MessagingPersistResult] {
        let threads = try await repository.listMessagingThreads(pluginID: pluginID)
        guard !threads.isEmpty else { return [] }
        let connector = try await repository.listMessagingConnectors()
            .first(where: { $0.pluginID == pluginID })
        let ordered = Self.orderedThreads(
            threads,
            preferredVendorThreadID: preferredVendorThreadID,
            channelOffset: channelOffset
        )
        let channelLimit = max(1, maxChannelPolls ?? ordered.count)
        let channels = Array(ordered.prefix(channelLimit))
        let preferredParent = preferredParentVendorMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var inserted: [MessagingPersistResult] = []
        // Docker guest is one slot. Extra reply-thread invokes are what made inbound
        // feel 30s–1min. Poll replies only when the UI has that thread open, or one
        // catch-up invoke when Derrick is not looking at a specific conversation.
        let watchingConversation = !(preferredVendorThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        var replyPollsRemaining = 0
        if !preferredParent.isEmpty {
            replyPollsRemaining = 1
        } else if !watchingConversation {
            replyPollsRemaining = 1
        }
        for thread in channels {
            inserted.append(
                contentsOf: try await pollConversation(
                    thread: thread,
                    parentVendorMessageID: nil,
                    repository: repository,
                    connector: connector
                )
            )
            if !preferredParent.isEmpty, thread.vendorThreadID == preferredVendorThreadID {
                inserted.append(
                    contentsOf: try await pollConversation(
                        thread: thread,
                        parentVendorMessageID: preferredParent,
                        repository: repository,
                        connector: connector
                    )
                )
                replyPollsRemaining = 0
                continue
            }
            guard replyPollsRemaining > 0 else { continue }
            let parents = try await replyParentsNeedingSync(
                thread: thread,
                repository: repository,
                limit: replyPollsRemaining
            )
            for parentID in parents {
                inserted.append(
                    contentsOf: try await pollConversation(
                        thread: thread,
                        parentVendorMessageID: parentID,
                        repository: repository,
                        connector: connector
                    )
                )
                replyPollsRemaining -= 1
            }
        }
        return inserted
    }

    static func orderedThreads(
        _ threads: [MessagingThreadDTO],
        preferredVendorThreadID: String?,
        channelOffset: Int = 0
    ) -> [MessagingThreadDTO] {
        let preferred = preferredVendorThreadID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preferred.isEmpty,
           let index = threads.firstIndex(where: { $0.vendorThreadID == preferred }) {
            var ordered = threads
            let focused = ordered.remove(at: index)
            ordered.insert(focused, at: 0)
            return ordered
        }
        guard threads.count > 1 else { return threads }
        let start = ((channelOffset % threads.count) + threads.count) % threads.count
        return Array(threads[start...]) + Array(threads[..<start])
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
        let parent = parentVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !parent.isEmpty {
            params["parent_vendor_message_id"] = .string(parent)
            params["thread_ts"] = .string(parent)
        } else if let cursor = try await pollCursor(
            for: thread,
            filter: .channelRoots,
            repository: repository
        ) {
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
        try Self.throwIfReplyThreadBlocked(
            result: result,
            parentVendorMessageID: parent.isEmpty ? nil : parent
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

    /// Channel history does not include nested replies. Some vendors also exclude the
    /// `oldest` cursor message unless `inclusive` is set, so stored `reply_count`
    /// can stay stale after the first reply. Re-poll threaded parents, newest first.
    private func replyParentsNeedingSync(
        thread: MessagingThreadDTO,
        repository: DBRepository,
        limit: Int
    ) async throws -> [String] {
        guard limit > 0 else { return [] }
        let roots = try await repository.listMessagingMessages(
            threadID: thread.id,
            limit: MessagingViewport.maxVisibleMessages,
            filter: .channelRoots
        )
        var behind: [String] = []
        var active: [String] = []
        for root in roots.reversed() {
            guard let vendorID = root.vendorMessageID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !vendorID.isEmpty
            else {
                continue
            }
            let threadRows = try await repository.listMessagingMessages(
                threadID: thread.id,
                limit: MessagingViewport.maxVisibleMessages,
                filter: .replyThread(parentVendorMessageID: vendorID)
            )
            let childCount = threadRows.filter { $0.parentVendorMessageID == vendorID }.count
            if childCount < root.replyCount {
                behind.append(vendorID)
            } else if root.replyCount > 0 || childCount > 0 {
                active.append(vendorID)
            }
        }
        return Array((behind + active).prefix(limit))
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
        let localID = UUID().uuidString
        let pending = MessagingMessageDTO(
            id: localID,
            threadID: threadID,
            vendorMessageID: "pending:\(localID)",
            direction: .outbound,
            sender: "derrick",
            body: trimmed,
            parentVendorMessageID: parentVendorMessageID
        )
        _ = try await repository.insertMessagingMessage(pending, incrementUnread: false)
        // Show in the host UI before the vendor round-trip finishes (agent + user sends).
        DerrickMessagingInboundSignal.postRefresh()
        do {
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
            try await repository.promoteMessagingOutbound(
                id: localID,
                vendorMessageID: sent.vendorMessageID,
                createdAt: sent.createdAt
            )
            DerrickMessagingInboundSignal.postRefresh()
        } catch {
            try? await repository.deleteMessagingMessage(id: localID)
            DerrickMessagingInboundSignal.postRefresh()
            throw error
        }
    }

    public func bootstrap(repository: DBRepository) async throws {
        let manifestJSON = try await repository.listLatestPluginFactoryManifests()
            .first(where: { $0.pluginID == pluginID })?
            .manifestJSON ?? ""
        // Always refresh the conversation catalog so every bot-visible channel appears as a tab.
        if PluginFactoryValidationExpectations.supportsSyncThreads(manifestJSON: manifestJSON) {
            try await syncThreads(repository: repository)
        }
        // Do not poll on bootstrap — that would import vendor history into SQLite.
        // Background ingress polls incrementally using listening_since / inbound cursors.
    }
}
