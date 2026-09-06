import Foundation
import Testing
@testable import Structure

@Suite struct VendorConversationMembershipFilterTests {
    @Test func dropsSlackChannelsTheBotIsNotIn() throws {
        let body = """
        {"ok":true,"channels":[\
        {"id":"C1","name":"general","is_member":true},\
        {"id":"C2","name":"secret","is_member":false}\
        ]}
        """
        let filtered = VendorConversationMembershipFilter.sanitizedBody(
            urlString: "https://slack.com/api/conversations.list?limit=200",
            body: body
        )
        let json = try #require(JSONSerialization.jsonObject(with: Data(filtered.utf8)) as? [String: Any])
        let channels = try #require(json["channels"] as? [[String: Any]])
        #expect(channels.count == 1)
        #expect(channels.first?["id"] as? String == "C1")
    }

    @Test func keepsChannelsWhenMembershipFlagIsMissing() throws {
        let body = #"{"ok":true,"channels":[{"id":"C123","name":"general"}]}"#
        let filtered = VendorConversationMembershipFilter.sanitizedBody(
            urlString: "https://slack.com/api/conversations.list",
            body: body
        )
        #expect(filtered == body)
    }

    @Test func leavesNonListEndpointsUnchanged() {
        let body = #"{"ok":true,"channels":[{"id":"C2","is_member":false}]}"#
        let filtered = VendorConversationMembershipFilter.sanitizedBody(
            urlString: "https://slack.com/api/conversations.history?channel=C2",
            body: body
        )
        #expect(filtered == body)
    }
}
