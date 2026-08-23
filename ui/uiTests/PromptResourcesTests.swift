import Foundation
import Testing
@testable import ui

@Suite struct PromptResourcesTests {
    @Test func loadsConversationRAGInstructionsFromResourcesDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let fileURL = resources.appendingPathComponent("conversation_rag_instructions.md")
        try "  RAG instructions from file  \n".write(to: fileURL, atomically: true, encoding: .utf8)

        let instructions = try PromptResources.conversationRAGInstructions(from: root)

        #expect(instructions == "RAG instructions from file")
    }

    @Test func loadsMemorySummarizerInstructionsFromResourcesDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let fileURL = resources.appendingPathComponent("memory_summarizer_instructions.md")
        try "  Summarizer instructions from file  \n".write(to: fileURL, atomically: true, encoding: .utf8)

        let instructions = try PromptResources.memorySummarizerInstructions(from: root)

        #expect(instructions == "Summarizer instructions from file")
    }

    @Test func loadsMCPToolInstructionsFromResourcesDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        try "Tool instructions from file\n".write(
            to: resources.appendingPathComponent("mcp_tool_instructions.md"),
            atomically: true,
            encoding: .utf8
        )

        #expect(try PromptResources.mcpToolInstructions(from: root) == "Tool instructions from file")
    }

    @Test func loadsWebCrawlerSkillFromResourcesDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        try "Web crawler skill from file\n".write(
            to: resources.appendingPathComponent("web_crawler_skill.md"),
            atomically: true,
            encoding: .utf8
        )

        #expect(try PromptResources.webCrawlerSkill(from: root) == "Web crawler skill from file")
    }

    @Test func loadsFilesExtractSkillFromResourcesDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        try "File extractor skill from file\n".write(
            to: resources.appendingPathComponent("files_extract_skill.md"),
            atomically: true,
            encoding: .utf8
        )

        #expect(try PromptResources.filesExtractSkill(from: root) == "File extractor skill from file")
    }

    @Test func loadsGuestSDKFromResourcesDirectory() throws {
        let source = try PromptResources.guestSDKSource()
        #expect(source.contains("standalone Swift executable"))
        let wrapped = try PromptResources.guestSDKForModel()
        #expect(wrapped.contains("```swift"))
        #expect(wrapped.contains("Swift plugin contract"))
    }

    @Test func throwsWhenConversationRAGInstructionsAreMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let expectedError = PromptResourcesError.missingResource(
            name: "conversation_rag_instructions",
            resourceRoot: root
        )
        var matchedExpectedError = false
        var sawUnexpectedError = false

        do {
            _ = try PromptResources.conversationRAGInstructions(from: root)
        } catch let error as PromptResourcesError {
            matchedExpectedError = error == expectedError
        } catch {
            sawUnexpectedError = true
        }

        #expect(matchedExpectedError)
        #expect(!sawUnexpectedError)
    }

    @Test func throwsWhenMemorySummarizerInstructionsAreMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let expectedError = PromptResourcesError.missingResource(
            name: "memory_summarizer_instructions",
            resourceRoot: root
        )
        var matchedExpectedError = false
        var sawUnexpectedError = false

        do {
            _ = try PromptResources.memorySummarizerInstructions(from: root)
        } catch let error as PromptResourcesError {
            matchedExpectedError = error == expectedError
        } catch {
            sawUnexpectedError = true
        }

        #expect(matchedExpectedError)
        #expect(!sawUnexpectedError)
    }

    @Test func throwsWhenMCPToolInstructionsAreMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let instructionsError = PromptResourcesError.missingResource(
            name: "mcp_tool_instructions",
            resourceRoot: root
        )
        var matchedInstructionsError = false

        do {
            _ = try PromptResources.mcpToolInstructions(from: root)
        } catch let error as PromptResourcesError {
            matchedInstructionsError = error == instructionsError
        }

        #expect(matchedInstructionsError)
    }
}
