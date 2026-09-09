import Foundation
import Structure
import Testing

@Suite struct AgentProfileTests {
    @Test func tokenParserExtractsHandleAndBody() {
        let parsed = AgentProfileTokenParser.parse(message: "$reviewer summarize this thread")
        #expect(parsed.handle == "reviewer")
        #expect(parsed.body == "summarize this thread")
    }

    @Test func tokenParserLeavesPlainMessageUntouched() {
        let parsed = AgentProfileTokenParser.parse(message: "hello team")
        #expect(parsed.handle == nil)
        #expect(parsed.body == "hello team")
    }

    @Test func tokenParserHandleOnly() {
        let parsed = AgentProfileTokenParser.parse(message: "$orchestrator")
        #expect(parsed.handle == "orchestrator")
        #expect(parsed.body == "")
    }

    @Test func tokenParserFindsHandleAfterGreeting() {
        let parsed = AgentProfileTokenParser.parse(message: "hi $orchestrator how are you?")
        #expect(parsed.handle == "orchestrator")
        #expect(parsed.body == "hi how are you?")

        let handleOnlyGreeting = AgentProfileTokenParser.parse(message: "hi $orchestrator")
        #expect(handleOnlyGreeting.handle == "orchestrator")
        #expect(handleOnlyGreeting.body == "hi")
    }

    @Test func tokenParserIgnoresDollarAmounts() {
        let parsed = AgentProfileTokenParser.parse(message: "price is $100")
        #expect(parsed.handle == nil)
        #expect(parsed.body == "price is $100")
    }

    @Test func handleValidationRejectsInvalidCharacters() {
        #expect(AgentProfileHandle.isValid("reviewer"))
        #expect(AgentProfileHandle.isValid("code_reviewer_2"))
        #expect(AgentProfileHandle.isValid("bad-handle") == false)
        #expect(AgentProfileHandle.normalize("Reviewer") == "reviewer")
    }

    @Test func turnContextRoundTrip() throws {
        let profile = AgentProfile.orchestratorDefault(modelJSON: Data(#"{"openai":"gpt-5.6-luna"}"#.utf8))
        let context = AgentProfileTurnContext(profile: profile)
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(AgentProfileTurnContext.self, from: data)
        #expect(decoded.handle == "orchestrator")
        #expect(decoded.displayName == "Orchestrator")
    }

    @Test func builtinProfilesIncludeOrchestratorAndDeveloper() {
        let modelJSON = Data(#"{"openai":"gpt-5.6-luna"}"#.utf8)
        let profiles = AgentProfile.builtinProfiles(modelJSON: modelJSON)
        #expect(profiles.count == 2)
        #expect(profiles.map(\.handle).contains(AgentProfileHandle.orchestrator))
        #expect(profiles.map(\.handle).contains(AgentProfileHandle.developer))
    }

    @Test func tokenHighlightFindsDollarHandlesAndPrefixedProfileNames() {
        let inbound = "$orchestrator tell me about yourself"
        let inboundTokens = AgentProfileTokenHighlight.ranges(in: inbound).map { String(inbound[$0]) }
        #expect(inboundTokens == ["$orchestrator"])

        let outbound = "[Derrick:developer] Fixed the build."
        let outboundTokens = AgentProfileTokenHighlight.ranges(in: outbound).map { String(outbound[$0]) }
        #expect(outboundTokens == ["developer"])

        let ignored = AgentProfileTokenHighlight.ranges(in: "price is $100")
        #expect(ignored.isEmpty)
    }
}
