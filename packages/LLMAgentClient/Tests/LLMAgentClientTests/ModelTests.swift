import Foundation
import Testing
@testable import LLMAgentClient

@Suite("Model Definitions")
struct ModelTests {
    @Test func openAIModelIdentifier() {
        #expect(OpenAIModel.gpt56Luna.id.provider == "openai")
        #expect(OpenAIModel.gpt56Luna.id.rawValue == "gpt-5.6-luna")
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
        #expect(OpenAIModel.gpt56Luna.maxSupportedContextTokens > OpenAIModel.gpt56Luna.maxIdealContextTokens)
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

    @Test func geminiJSONStreamRequestSerialization() throws {
        let schema = AgentSchema(
            type: .object,
            properties: [
                "message_type": AgentSchema(type: .string, description: "Type of message"),
                "status": AgentSchema(type: .string, description: "System status")
            ],
            required: ["message_type"]
        )

        let request = GeminiJSONStreamRequest(
            messages: [
                .init(role: .system, content: "You are a concise JSON generator."),
                .init(role: .user, content: "Update status")
            ],
            temperature: 0.7,
            responseSchema: schema
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let jsonString = String(decoding: data, as: UTF8.self)

        #expect(jsonString.contains("application\\/json"))
        #expect(jsonString.contains("OBJECT"))
        #expect(jsonString.contains("message_type"))
        #expect(jsonString.contains("status"))
        #expect(jsonString.contains("STRING"))
        #expect(jsonString.contains("Type of message"))
        #expect(jsonString.contains("System status"))
    }

    @Test func openAIJSONStreamRequestSerialization() throws {
        let schema = AgentSchema(
            type: .object,
            properties: [
                "status": AgentSchema(type: .string, description: "System status"),
                "thought": AgentSchema(type: .string, description: "System thoughts")
            ],
            required: ["status"]
        )

        let request = OpenAIStreamRequest(
            model: "gpt-5.6-luna",
            messages: [
                .init(role: .system, content: "You are a concise JSON generator."),
                .init(role: .user, content: "Update status")
            ],
            temperature: 0.1,
            responseSchema: schema
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(request)
        let jsonString = String(decoding: data, as: UTF8.self)
        
        print("\n=== DIAGNOSTIC TEST SCHEMA OUTPUT ===\n\(jsonString)\n=====================================\n")

        #expect(jsonString.contains("json_schema"))
        #expect(jsonString.contains("strict"))
        #expect(jsonString.contains("additionalProperties"))
        #expect(jsonString.contains("false"))
        #expect(jsonString.contains("null"))
        #expect(jsonString.contains("status"))
        #expect(jsonString.contains("thought"))
    }

    @Test func realAgentSchemaSerialization() throws {
        let schema = AgentSchema(
            type: .object,
            properties: [
                "status": AgentSchema(type: .string, description: "System status"),
                "thought": AgentSchema(type: .string, description: "Your internal plan or reasoning steps"),
                "assistant_response": AgentSchema(type: .string, description: "The markdown, json or csv message content meant for user."),
                "tool_call": AgentSchema(
                    type: .object,
                    properties: [
                        "tool_name": AgentSchema(type: .string, description: "Name of the tool to execute"),
                        "arguments": AgentSchema(type: .string, description: "JSON-formatted string of tool arguments")
                    ],
                    required: ["tool_name", "arguments"]
                ),
                "tool_batch": AgentSchema(
                    type: .object,
                    properties: [
                        "invocations": AgentSchema(
                            type: .array,
                            items: AgentSchema(
                                type: .object,
                                properties: [
                                    "tool_name": AgentSchema(type: .string, description: "Name of the tool to execute"),
                                    "arguments": AgentSchema(type: .string, description: "JSON-formatted string of tool arguments")
                                ],
                                required: ["tool_name", "arguments"]
                            ),
                            description: "Array of tool invocation objects"
                        ),
                   ],
                   required: ["invocations"]
                )
            ],
            required: ["status"],
        )

        let request = OpenAIStreamRequest(
            model: "gpt-5.6-luna",
            messages: [.init(role: .user, content: "test")],
            temperature: 0.1,
            responseSchema: schema
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(request)
        let jsonString = String(decoding: data, as: UTF8.self)
        
        print("\n=== DIAGNOSTIC REAL SCHEMA OUTPUT ===\n\(jsonString)\n=====================================\n")
    }
}
