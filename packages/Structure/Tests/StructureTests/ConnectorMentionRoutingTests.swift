import Foundation
import Structure
import Testing

@Suite struct ConnectorMentionRoutingTests {
    @Test func mentionsSlackUserDetectsPlainAndLabeledMentions() {
        #expect(ConnectorMentionParser.mentionsSlackUser(body: "hey <@U123> help", userID: "U123"))
        #expect(ConnectorMentionParser.mentionsSlackUser(body: "hey <@U123|derrick> help", userID: "U123"))
        #expect(ConnectorMentionParser.mentionsSlackUser(body: "hey <@U999> help", userID: "U123") == false)
    }

    @Test func stripSlackUserMentionRemovesToken() {
        let stripped = ConnectorMentionParser.stripSlackUserMention(
            body: "<@U123|derrick> $reviewer summarize this",
            userID: "U123"
        )
        #expect(stripped == "$reviewer summarize this")
    }

    @Test func resolvePromptUsesProfileTokenAndDefault() {
        let withProfile = ConnectorMentionParser.resolvePrompt(
            body: "<@U123> $reviewer summarize",
            botUserID: "U123"
        )
        #expect(withProfile?.profileHandle == "reviewer")
        #expect(withProfile?.prompt == "summarize")

        let defaultProfile = ConnectorMentionParser.resolvePrompt(
            body: "<@U123> what is blocking release?",
            botUserID: "U123"
        )
        #expect(defaultProfile?.profileHandle == AgentProfileHandle.orchestrator)
        #expect(defaultProfile?.prompt == "what is blocking release?")
    }

    @Test func resolvePromptRoutesBareProfileTokenWithoutBotMention() {
        let routed = ConnectorMentionParser.resolvePrompt(
            body: "$orchestrator tell me about yourself",
            botUserID: "U123"
        )
        #expect(routed?.profileHandle == AgentProfileHandle.orchestrator)
        #expect(routed?.prompt == "tell me about yourself")

        let withoutBotIdentity = ConnectorMentionParser.resolvePrompt(
            body: "$developer fix the build",
            botUserID: ""
        )
        #expect(withoutBotIdentity?.profileHandle == "developer")
        #expect(withoutBotIdentity?.prompt == "fix the build")
    }

    @Test func resolvePromptRoutesProfileTokenAfterGreeting() {
        let routed = ConnectorMentionParser.resolvePrompt(
            body: "hi $orchestrator how are you?",
            botUserID: "U123"
        )
        #expect(routed?.profileHandle == AgentProfileHandle.orchestrator)
        #expect(routed?.prompt == "hi how are you?")
    }

    @Test func resolvePromptIgnoresPlainInboundWithoutMentionOrHandle() {
        let ignored = ConnectorMentionParser.resolvePrompt(
            body: "hello without mention",
            botUserID: "U123"
        )
        #expect(ignored == nil)
    }

    @Test func resolvePromptUsesChannelDefaultProfile() {
        let resolved = ConnectorMentionParser.resolvePrompt(
            body: "<@U123> what is blocking release?",
            botUserID: "U123",
            channelDefaultProfileHandle: "researcher"
        )
        #expect(resolved?.profileHandle == AgentProfileHandle.researcher)
        #expect(resolved?.prompt == "what is blocking release?")
    }

    @Test func mentionOnlyPromptListsProfiles() {
        let prompt = ConnectorMentionParser.resolvePrompt(
            body: "<@U123>",
            botUserID: "U123",
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

    @Test func parseBotUserIDFromAuthTestPayload() {
        let json = Data(#"{"ok":true,"user_id":"U07BOT","bot_id":"B07BOT"}"#.utf8)
        #expect(SlackBotIdentityResolver.parseBotUserID(from: json) == "U07BOT")
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
            botUserID: "U123",
            continuationProfileHandle: AgentProfileHandle.developer
        )
        #expect(continued?.profileHandle == AgentProfileHandle.developer)
        #expect(continued?.prompt == "tell me about yourself")

        let switched = ConnectorMentionParser.resolvePrompt(
            body: "$developer tell me about yourself",
            botUserID: "U123",
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
