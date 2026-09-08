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
        let general = profiles.first { $0.handle == "general" }!

        let orchestratorModel = try JSONDecoder().decode(LLMModelChoice.self, from: orchestrator.modelJSON)
        let developerModel = try JSONDecoder().decode(LLMModelChoice.self, from: developer.modelJSON)
        let researcherModel = try JSONDecoder().decode(LLMModelChoice.self, from: researcher.modelJSON)
        let generalModel = try JSONDecoder().decode(LLMModelChoice.self, from: general.modelJSON)

        #expect(orchestratorModel.id == "openai:gpt-5.6-sol")
        #expect(developerModel.id == "openai:gpt-5.6-terra")
        #expect(researcherModel.id == "openai:gpt-5.6-terra")
        #expect(generalModel.id == "openai:gpt-5.6-luna")

        let orchestratorThinking = try JSONDecoder().decode(
            ModelThinkingOption.self,
            from: orchestrator.thinkingJSON!
        )
        #expect(orchestratorThinking.id == "high")
    }
}
