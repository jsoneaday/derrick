import Foundation
import Plugin
import ServiceContracts

/// Applies vendor-agnostic connector plugin results to messaging tables.
public enum ConnectorMessagingPersistence: Sendable {
    @discardableResult
    public static func apply(
        _ result: ConnectorMessagingResult,
        pluginID: String,
        repository: DBRepository
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

        var inserted: [MessagingPersistResult] = []
        let threads = try await repository.listMessagingThreads(pluginID: pluginID)
        let threadsByVendorID = Dictionary(uniqueKeysWithValues: threads.map { ($0.vendorThreadID, $0) })

        for message in result.messages {
            guard let thread = threadsByVendorID[message.vendorThreadID] else { continue }
            switch message.direction {
            case .inbound:
                let record = MessagingInboundRecord(
                    pluginID: pluginID,
                    vendorThreadID: message.vendorThreadID,
                    threadTitle: thread.title,
                    vendorMessageID: message.vendorMessageID,
                    sender: message.sender,
                    body: message.body,
                    createdAt: message.createdAt,
                    countAsUnread: true
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
                    createdAt: message.createdAt
                )
                _ = try await repository.insertMessagingMessage(outbound, incrementUnread: false)
            }
        }
        return inserted
    }
}
