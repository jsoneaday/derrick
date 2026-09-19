import Foundation
import Structure
import Testing
@testable import ui

@Suite struct MessagingInboundBannerDedupeTests {
    @Test func prefersVendorMessageID() {
        let message = MessagingMessageDTO(
            id: "local-1",
            threadID: "thread-a",
            vendorMessageID: "171.07647",
            direction: .inbound,
            sender: "David",
            body: "07647"
        )
        #expect(MessagingInboundBannerDedupe.key(for: message) == "thread-a#v:171.07647")
    }

    @Test func fallsBackToLocalID() {
        let message = MessagingMessageDTO(
            id: "local-2",
            threadID: "thread-a",
            direction: .inbound,
            sender: "David",
            body: "07647"
        )
        #expect(MessagingInboundBannerDedupe.key(for: message) == "thread-a#id:local-2")
    }

    @Test func freshKeysIgnoreAlreadyPresented() {
        let current: Set = ["thread-a#v:1", "thread-a#v:2"]
        let presented: Set = ["thread-a#v:1"]
        #expect(
            MessagingInboundBannerDedupe.freshKeys(current: current, alreadyPresented: presented)
                == ["thread-a#v:2"]
        )
    }
}
