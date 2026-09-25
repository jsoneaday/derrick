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

    @Test func tokenParserTalksToProfileAfterGreeting() {
        let parsed = AgentProfileTokenParser.parse(message: "hi $orchestrator how are you?")
        #expect(parsed.handle == "orchestrator")
        #expect(parsed.body == "how are you?")

        let handleOnlyGreeting = AgentProfileTokenParser.parse(message: "hi $orchestrator")
        #expect(handleOnlyGreeting.handle == "orchestrator")
        #expect(handleOnlyGreeting.body == "")
    }

    @Test func tokenParserTalksToProfileAtStartOfSentence() {
        let parsed = AgentProfileTokenParser.parse(
            message: "Quick question. $orchestrator what's today's date?"
        )
        #expect(parsed.handle == "orchestrator")
        #expect(parsed.body == "Quick question. what's today's date?")
    }

    @Test func tokenParserIgnoresMidClauseMention() {
        let parsed = AgentProfileTokenParser.parse(
            message: "it doesn't work? but $orchestrator told me it does work"
        )
        #expect(parsed.handle == nil)
        #expect(parsed.body == "it doesn't work? but $orchestrator told me it does work")
    }

    @Test func tokenParserIgnoresHandleUsedAsSubject() {
        let parsed = AgentProfileTokenParser.parse(message: "$orchestrator told me it does work")
        #expect(parsed.handle == nil)
        #expect(parsed.body == "$orchestrator told me it does work")
    }

    @Test func tokenParserTreatsCommaAsTalkTo() {
        let parsed = AgentProfileTokenParser.parse(message: "$orchestrator, what's the date?")
        #expect(parsed.handle == "orchestrator")
        #expect(parsed.body == "what's the date?")
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

    @Test func builtinProfilesIncludeAllBuiltins() {
        let modelJSON = Data(#"{"openai":"gpt-5.6-luna"}"#.utf8)
        let profiles = AgentProfile.builtinProfiles(modelJSON: modelJSON)
        #expect(profiles.count == 4)
        #expect(profiles.map(\.handle).contains(AgentProfileHandle.orchestrator))
        #expect(profiles.map(\.handle).contains(AgentProfileHandle.developer))
        #expect(profiles.map(\.handle).contains(AgentProfileHandle.researcher))
        #expect(profiles.map(\.handle).contains(AgentProfileHandle.generalist))
    }

    @Test func emptyCapabilitiesJSONUsesDefaults() throws {
        let decoded = try JSONDecoder().decode(AgentProfileCapabilities.self, from: Data("{}".utf8))
        #expect(decoded.allowsSubagent == false)
        #expect(decoded.allowsAllPlugins)
        #expect(decoded.allowsPlugin("slack-connector-1"))
        var limited = AgentProfileCapabilities(allowsAllPlugins: false, allowedPluginIDs: ["news"])
        #expect(limited.allowsPlugin("news"))
        #expect(!limited.allowsPlugin("slack-connector-1"))
        let orchestrator = AgentProfileCapabilities.orchestratorDefault()
        #expect(orchestrator.allowsScheduling)
        #expect(orchestrator.allowedSubagentHandles.contains(AgentProfileHandle.generalist))
        #expect(AgentProfileCapabilities.specialist.allowsSubagent)
    }

    @Test func delegateTargetsExcludeOrchestrator() {
        #expect(AgentProfileHandle.delegateTargets == [
            AgentProfileHandle.developer,
            AgentProfileHandle.researcher,
            AgentProfileHandle.generalist,
        ])
    }

    @Test func tokenHighlightFindsDollarHandlesAndPrefixedProfileNames() {
        let inbound = "$orchestrator tell me about yourself"
        let inboundTokens = AgentProfileTokenHighlight.ranges(in: inbound).map { String(inbound[$0]) }
        #expect(inboundTokens == ["$orchestrator"])

        let outbound = "[Derrick:$developer] Fixed the build."
        let outboundTokens = AgentProfileTokenHighlight.ranges(in: outbound).map { String(outbound[$0]) }
        #expect(outboundTokens == ["[Derrick:$developer]"])

        let legacy = "[Derrick:developer] Fixed the build."
        let legacyTokens = AgentProfileTokenHighlight.ranges(in: legacy).map { String(legacy[$0]) }
        #expect(legacyTokens == ["[Derrick:developer]"])

        let ignored = AgentProfileTokenHighlight.ranges(in: "price is $100")
        #expect(ignored.isEmpty)
    }
}
