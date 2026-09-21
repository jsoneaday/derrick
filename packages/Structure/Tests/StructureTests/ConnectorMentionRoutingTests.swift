import Foundation
import Structure
import Testing

@Suite struct ConnectorMentionRoutingTests {
    @Test func resolvePromptUsesTalkToHandle() {
        let withProfile = ConnectorMentionParser.resolvePrompt(
            body: "$reviewer summarize"
        )
        #expect(withProfile?.profileHandle == "reviewer")
        #expect(withProfile?.prompt == "summarize")
    }

    @Test func resolvePromptRoutesBareProfileToken() {
        let routed = ConnectorMentionParser.resolvePrompt(
            body: "$orchestrator tell me about yourself"
        )
        #expect(routed?.profileHandle == AgentProfileHandle.orchestrator)
        #expect(routed?.prompt == "tell me about yourself")
    }

    @Test func resolvePromptRoutesProfileTokenAfterGreeting() {
        let routed = ConnectorMentionParser.resolvePrompt(
            body: "hi $orchestrator how are you?"
        )
        #expect(routed?.profileHandle == AgentProfileHandle.orchestrator)
        #expect(routed?.prompt == "how are you?")
    }

    @Test func resolvePromptIgnoresMidClauseProfileMention() {
        let ignored = ConnectorMentionParser.resolvePrompt(
            body: "it doesn't work? but $orchestrator told me it does work"
        )
        #expect(ignored == nil)
    }

    @Test func agentWorkStatusLabelUsesDisplayName() {
        let work = MessagingAgentWorkInFlight(
            pluginID: "slack-connection",
            threadID: "t1",
            parentVendorMessageID: "171.1",
            profileHandle: AgentProfileHandle.orchestrator,
            displayName: "Orchestrator"
        )
        #expect(work.statusLabel == "Orchestrator is working")
    }

    @Test func resolvePromptIgnoresPlainInboundWithoutHandle() {
        let ignored = ConnectorMentionParser.resolvePrompt(
            body: "hello without mention"
        )
        #expect(ignored == nil)
    }

    @Test func resolvePromptDoesNotTreatVendorAtMentionAsTalkTo() {
        let ignored = ConnectorMentionParser.resolvePrompt(
            body: "<@U123> what is blocking release?",
            channelDefaultProfileHandle: "researcher"
        )
        #expect(ignored == nil)
    }

    @Test func mentionOnlyPromptListsProfiles() {
        let prompt = ConnectorMentionParser.resolvePrompt(
            body: "$orchestrator",
            profileCatalog: [
                AgentProfileCatalogEntry(handle: "orchestrator", displayName: "Orchestrator"),
                AgentProfileCatalogEntry(handle: "developer", displayName: "Developer"),
            ]
        )?.prompt
        #expect(prompt?.contains("$orchestrator") == true)
        #expect(prompt?.contains("$developer") == true)
    }

    @Test func outboundFormatterPrefixesBotNameAndProfile() {
        let formatted = MessagingAgentOutboundFormatter.formatReply(
            "Done.",
            profileHandle: AgentProfileHandle.orchestrator
        )
        #expect(formatted == "[Derrick:orchestrator] Done.")

        let developer = MessagingAgentOutboundFormatter.formatReply(
            "Fixed the build.",
            profileHandle: AgentProfileHandle.developer
        )
        #expect(developer == "[Derrick:developer] Fixed the build.")
    }

    @Test func automatedOutboundEchoDetectsProfilePrefixedReplies() {
        #expect(ConnectorMentionParser.isAutomatedOutboundEcho(body: "[Derrick:orchestrator] hello"))
        #expect(ConnectorMentionParser.isAutomatedOutboundEcho(body: "[Derrick] hello"))
        #expect(ConnectorMentionParser.isAutomatedOutboundEcho(body: "plain inbound") == false)
    }

    @Test func agentReplyThreadsUnderInboundRootWhenNoParent() {
        let inbound = "1710000002.000200"
        let parent = ConnectorMentionParser.agentReplyThreadParentVendorMessageID(
            inboundVendorMessageID: inbound,
            existingParentVendorMessageID: nil
        )
        #expect(parent == inbound)

        let alreadyThreaded = ConnectorMentionParser.agentReplyThreadParentVendorMessageID(
            inboundVendorMessageID: "1710000003.000300",
            existingParentVendorMessageID: inbound
        )
        #expect(alreadyThreaded == inbound)
    }

    @Test func resolvePromptContinuesThreadProfileWithoutDollarToken() {
        let continued = ConnectorMentionParser.resolvePrompt(
            body: "tell me about yourself",
            continuationProfileHandle: AgentProfileHandle.developer
        )
        #expect(continued?.profileHandle == AgentProfileHandle.developer)
        #expect(continued?.prompt == "tell me about yourself")

        let switched = ConnectorMentionParser.resolvePrompt(
            body: "$developer tell me about yourself",
            continuationProfileHandle: AgentProfileHandle.orchestrator
        )
        #expect(switched?.profileHandle == AgentProfileHandle.developer)
    }

    @Test func continuationProfileHandleUsesLatestDerrickReply() {
        let messages = [
            MessagingMessageDTO(
                threadID: "t1",
                vendorMessageID: "1",
                direction: .inbound,
                sender: "U1",
                body: "$orchestrator what's today's date?"
            ),
            MessagingMessageDTO(
                threadID: "t1",
                vendorMessageID: "2",
                direction: .outbound,
                sender: "derrick",
                body: "[Derrick:orchestrator] Today is Tuesday.",
                parentVendorMessageID: "1"
            ),
            MessagingMessageDTO(
                threadID: "t1",
                vendorMessageID: "3",
                direction: .outbound,
                sender: "derrick",
                body: "[Derrick:developer] I’m the developer profile.",
                parentVendorMessageID: "1"
            ),
        ]
        #expect(
            ConnectorMentionParser.continuationProfileHandle(
                in: messages,
                excludingVendorMessageID: "4"
            ) == AgentProfileHandle.developer
        )
        #expect(
            ConnectorMentionParser.profileHandle(inMessageBody: "[Derrick:developer] hi")
                == AgentProfileHandle.developer
        )
    }
}
