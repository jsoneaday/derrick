import Foundation
import Structure
import Testing
@testable import ui

@MainActor
@Suite struct MessagingOptimisticMergeTests {
    @Test func keepsPendingUntilPersistedTwinArrives() {
        let threadID = "thread-1"
        let pending = MessagingMessageDTO(
            id: "pending-1",
            threadID: threadID,
            direction: .outbound,
            sender: "derrick",
            body: "hi from derrick",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let inbound = MessagingMessageDTO(
            id: "in-1",
            threadID: threadID,
            vendorMessageID: "v-in",
            direction: .inbound,
            sender: "someone",
            body: "hi from slack",
            createdAt: Date(timeIntervalSince1970: 90)
        )

        let beforeAck = MessagingSessionStore.merging(persisted: [inbound], pending: [pending])
        #expect(beforeAck.map(\.id) == ["in-1", "pending-1"])

        let persisted = MessagingMessageDTO(
            id: "persisted-1",
            threadID: threadID,
            vendorMessageID: "v-out",
            direction: .outbound,
            sender: "derrick",
            body: "hi from derrick",
            createdAt: Date(timeIntervalSince1970: 101)
        )
        let afterAck = MessagingSessionStore.merging(persisted: [inbound, persisted], pending: [pending])
        #expect(afterAck.map(\.id) == ["in-1", "persisted-1"])
    }

    @Test func doesNotCollapseTwoIdenticalOutboundSends() {
        let threadID = "thread-1"
        let pendingA = MessagingMessageDTO(
            id: "pending-a",
            threadID: threadID,
            direction: .outbound,
            sender: "derrick",
            body: "ping",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let pendingB = MessagingMessageDTO(
            id: "pending-b",
            threadID: threadID,
            direction: .outbound,
            sender: "derrick",
            body: "ping",
            createdAt: Date(timeIntervalSince1970: 101)
        )
        let persisted = MessagingMessageDTO(
            id: "persisted-1",
            threadID: threadID,
            vendorMessageID: "v-1",
            direction: .outbound,
            sender: "derrick",
            body: "ping",
            createdAt: Date(timeIntervalSince1970: 100.5)
        )

        let merged = MessagingSessionStore.merging(
            persisted: [persisted],
            pending: [pendingA, pendingB]
        )
        #expect(merged.count == 2)
        #expect(merged.contains(where: { $0.id == "persisted-1" }))
        #expect(merged.contains(where: { $0.id == "pending-b" || $0.id == "pending-a" }))
    }
}
