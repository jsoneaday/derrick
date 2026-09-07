import Foundation
import Testing
@testable import Structure

@Suite struct SlackUserDisplayNameResolverTests {
    @Test func parseDisplayNamePrefersProfileDisplayName() {
        let json = """
        {"ok":true,"user":{"id":"U07FKG8DV19","name":"david.choi","real_name":"David Choi","profile":{"display_name":"David"}}}
        """.data(using: .utf8)!
        #expect(SlackUserDisplayNameResolver.parseDisplayName(from: json) == "David")
    }

    @Test func parseDisplayNameFallsBackToRealName() {
        let json = """
        {"ok":true,"user":{"id":"U07FKG8DV19","name":"david.choi","real_name":"David Choi","profile":{"display_name":""}}}
        """.data(using: .utf8)!
        #expect(SlackUserDisplayNameResolver.parseDisplayName(from: json) == "David Choi")
    }

    @Test func parseDisplayNameFallsBackToUsername() {
        let json = """
        {"ok":true,"user":{"id":"U07FKG8DV19","name":"david.choi","real_name":"","profile":{}}}
        """.data(using: .utf8)!
        #expect(SlackUserDisplayNameResolver.parseDisplayName(from: json) == "david.choi")
    }

    @Test func previewBodyUsesHumanSender() {
        #expect(
            MessagingInboundNotificationCopy.previewBody(
                sender: "David",
                body: "bt4",
                isReply: true
            ) == "David: bt4"
        )
    }
}
