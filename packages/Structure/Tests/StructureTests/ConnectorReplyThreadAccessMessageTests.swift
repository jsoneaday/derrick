import Testing
@testable import Structure

@Suite struct ConnectorReplyThreadAccessMessageTests {
    @Test func mapsSlackMissingScopeToReadPermissionCopy() {
        let message = ConnectorReplyThreadAccessMessage.userFacing(
            fromVendorDetail: "Slack replies failed: missing_scope"
        )
        #expect(message == ConnectorReplyThreadAccessMessage.slackBlockedThread)
        #expect(message?.localizedCaseInsensitiveContains("missing_scope") != true)
    }

    @Test func mapsNotInChannelWithoutVendorJargon() {
        let message = ConnectorReplyThreadAccessMessage.userFacing(
            fromVendorDetail: "not_in_channel"
        )
        #expect(message == ConnectorReplyThreadAccessMessage.botNotInChannel)
    }

    @Test func ignoresUnrelatedPluginSummaries() {
        #expect(ConnectorReplyThreadAccessMessage.userFacing(fromVendorDetail: "unsupported") == nil)
    }
}
