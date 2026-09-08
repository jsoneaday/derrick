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

    @Test func outboundFormatterPrefixesBotName() {
        let formatted = MessagingAgentOutboundFormatter.formatReply("Done.")
        #expect(formatted == "[Derrick] Done.")
    }

    @Test func parseBotUserIDFromAuthTestPayload() {
        let json = Data(#"{"ok":true,"user_id":"U07BOT","bot_id":"B07BOT"}"#.utf8)
        #expect(SlackBotIdentityResolver.parseBotUserID(from: json) == "U07BOT")
    }
}
