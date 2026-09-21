import Foundation
import Testing
@testable import Structure

@Suite struct MessagingSenderDisplayNameTests {
    @Test func previewBodyUsesHumanSender() {
        #expect(
            MessagingInboundNotificationCopy.previewBody(
                sender: "David",
                body: "bt4",
                isReply: true
            ) == "David: bt4"
        )
    }

    @Test func unresolvedOpaqueIdStaysUnchangedWithoutAdapter() async {
        await VendorActorDirectory.shared.setDisplayNameResolver(nil)
        let sender = await MessagingSenderDisplayName.resolve(
            pluginID: "any",
            sender: "U07FKG8DV19"
        )
        #expect(sender == "U07FKG8DV19")
    }
}
