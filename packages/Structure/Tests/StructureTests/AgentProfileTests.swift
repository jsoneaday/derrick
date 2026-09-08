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
}
