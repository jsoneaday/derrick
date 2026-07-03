import Testing
@testable import LLMAgentClient

@Suite("Model Definitions")
struct ModelTests {
    @Test func openAIModelIdentifier() {
        #expect(OpenAIModel.gpt5Mini.id.provider == "openai")
        #expect(OpenAIModel.gpt5Mini.id.rawValue == "gpt-5-mini")
    }

    @Test func geminiModelIdentifier() {
        #expect(GeminiModel.gemini31FlashLite.id.provider == "gemini")
        #expect(GeminiModel.gemini31FlashLite.id.rawValue == "gemini-3.1-flash-lite")
        #expect(GeminiModel.gemini31FlashLite.maxSupportedContextTokens > GeminiModel.gemini31FlashLite.maxIdealContextTokens)
    }

    @Test func requestPromptBuildsMessages() {
        let request = AgentRequest.prompt("Hello", system: "You are concise.")
        #expect(request.messages.count == 2)
        #expect(request.messages.first?.role == .system)
        #expect(request.messages.last?.role == .user)
    }

    @Test func openAIModelContextBudgetsArePresent() {
        #expect(OpenAIModel.gpt5Mini.maxSupportedContextTokens > OpenAIModel.gpt5Mini.maxIdealContextTokens)
    }
}
