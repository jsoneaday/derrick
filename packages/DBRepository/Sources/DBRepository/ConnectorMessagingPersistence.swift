import Foundation
import Plugin
import Structure

/// Applies vendor-agnostic connector plugin results to messaging tables.
public enum ConnectorMessagingPersistence: Sendable {
    @discardableResult
    public static func apply(
        _ result: ConnectorMessagingResult,
        pluginID: String,
        repository: DBRepository,
        pollVendorThreadID: String? = nil,
        replaceThreadCatalog: Bool = false
    ) async throws -> [MessagingPersistResult] {
        for thread in result.threads {
            try await repository.upsertMessagingThread(
                MessagingThreadDTO(
                    pluginID: pluginID,
                    vendorThreadID: thread.vendorThreadID,
                    title: thread.title
                )
            )
        }
        if replaceThreadCatalog {
            try await repository.pruneMessagingThreads(
                pluginID: pluginID,
                keepingVendorThreadIDs: Set(result.threads.map(\.vendorThreadID))
            )
        }

        var inserted: [MessagingPersistResult] = []
        let threads = try await repository.listMessagingThreads(pluginID: pluginID)
        let threadsByVendorID = Dictionary(uniqueKeysWithValues: threads.map { ($0.vendorThreadID, $0) })

        for message in result.messages {
            let resolvedVendorThreadID = resolveVendorThreadID(
                message.vendorThreadID,
                threadsByVendorID: threadsByVendorID,
                pollVendorThreadID: pollVendorThreadID
            )
            guard let resolvedVendorThreadID,
                  let thread = threadsByVendorID[resolvedVendorThreadID] else {
                continue
            }
            switch message.direction {
            case .inbound:
                let sender = await MessagingSenderDisplayName.resolve(
                    pluginID: pluginID,
                    sender: message.sender
                )
                let record = MessagingInboundRecord(
                    pluginID: pluginID,
                    vendorThreadID: resolvedVendorThreadID,
                    threadTitle: thread.title,
                    vendorMessageID: message.vendorMessageID,
                    sender: sender,
                    body: message.body,
                    createdAt: message.createdAt,
                    countAsUnread: true,
                    parentVendorMessageID: message.parentVendorMessageID,
                    replyCount: message.replyCount
                )
                let persist = try await repository.persistMessagingInbound(record)
                if persist.inserted {
                    inserted.append(persist)
                }
            case .outbound:
                let outbound = MessagingMessageDTO(
                    threadID: thread.id,
                    vendorMessageID: message.vendorMessageID,
                    direction: .outbound,
                    sender: message.sender,
                    body: message.body,
                    createdAt: message.createdAt,
                    parentVendorMessageID: message.parentVendorMessageID,
                    replyCount: message.replyCount
                )
                _ = try await repository.insertMessagingMessage(outbound, incrementUnread: false)
            }
        }
        return inserted
    }

    private static func resolveVendorThreadID(
        _ vendorThreadID: String,
        threadsByVendorID: [String: MessagingThreadDTO],
        pollVendorThreadID: String?
    ) -> String? {
        if threadsByVendorID[vendorThreadID] != nil {
            return vendorThreadID
        }
        if let pollVendorThreadID,
           threadsByVendorID[pollVendorThreadID] != nil {
            return pollVendorThreadID
        }
        return nil
    }
}
