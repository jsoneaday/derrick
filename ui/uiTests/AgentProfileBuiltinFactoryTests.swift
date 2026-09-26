import Foundation
import LLMAgentClient
import Structure
import Testing
@testable import ui

@Suite struct AgentProfileBuiltinFactoryTests {
    @Test func builtinProfilesUseExpectedModels() throws {
        let profiles = try AgentProfileBuiltinFactory.all()
        #expect(profiles.count == 4)

        let orchestrator = profiles.first { $0.handle == "orchestrator" }!
        let developer = profiles.first { $0.handle == "developer" }!
        let researcher = profiles.first { $0.handle == "researcher" }!
        let generalist = profiles.first { $0.handle == "generalist" }!

        let orchestratorModel = try JSONDecoder().decode(LLMModelChoice.self, from: orchestrator.modelJSON)
        let developerModel = try JSONDecoder().decode(LLMModelChoice.self, from: developer.modelJSON)
        let researcherModel = try JSONDecoder().decode(LLMModelChoice.self, from: researcher.modelJSON)
        let generalistModel = try JSONDecoder().decode(LLMModelChoice.self, from: generalist.modelJSON)

        #expect(orchestratorModel.id == "openai:gpt-6-luna")
        #expect(developerModel.id == "openai:gpt-6-luna")
        #expect(researcherModel.id == "openai:gpt-6-luna")
        #expect(generalistModel.id == "openai:gpt-6-luna")

        let orchestratorThinking = try JSONDecoder().decode(
            ModelThinkingOption.self,
            from: orchestrator.thinkingJSON!
        )
        let developerThinking = try JSONDecoder().decode(
            ModelThinkingOption.self,
            from: developer.thinkingJSON!
        )
        #expect(orchestratorThinking.id == "high")
        #expect(developerThinking.id == "medium")
    }
}
