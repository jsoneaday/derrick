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

    @Test func openAIAdditionalModelsAreAvailable() {
        #expect(OpenAIModel.allCases.contains(.gpt54Mini))
        #expect(OpenAIModel.allCases.contains(.gpt54))
        #expect(OpenAIModel.allCases.contains(.gpt55))
        #expect(OpenAIModel.gpt54Mini.rawValue == "gpt-5.4-mini")
        #expect(OpenAIModel.gpt54.rawValue == "gpt-5.4")
        #expect(OpenAIModel.gpt55.rawValue == "gpt-5.5")
    }

    @Test func openAIStreamDecoderHandlesMultipleDataPayloads() throws {
        let event = """
        data: {"choices":[{"delta":{"content":"Hel"}}]}
        data: {"choices":[{"delta":{"content":"lo"}}]}

        data: [DONE]

        """
        let chunks = try openAITextChunks(from: event)
        #expect(chunks == ["Hel", "lo"])
    }
}
