import Foundation
import LLMAgentClient
import Plugin
import Testing
@testable import ui

@Suite struct ChatTurnStreamingTests {
    @Test func thinkingReplacesSnapshotInsteadOfAppendingPrefixes() {
        var turn = ChatTurn(prompt: "create a plugin")
        turn.applyStreamChunk(status: .thinking, chunk: "I'll start")
        turn.applyStreamChunk(status: .thinking, chunk: "I'll start a Software Factory session")
        turn.applyStreamChunk(status: .thinking, chunk: "I'll start a Software Factory session for daily-news.")
        #expect(turn.thought == "I'll start a Software Factory session for daily-news.")
        #expect(!turn.thought.contains("I'll startI'll start"))
        #expect(turn.response.isEmpty)
    }

    @Test func laterFactoryHopReplacesPriorThought() {
        var turn = ChatTurn(prompt: "create a plugin")
        turn.applyStreamChunk(status: .thinking, chunk: "I'll start a Software Factory session")
        turn.applyStreamChunk(status: .thinking, chunk: "Write the TypeScript handle next.")
        #expect(turn.thought == "Write the TypeScript handle next.")
    }

    @Test func completeStillAppendsAnswerDeltas() {
        var turn = ChatTurn(prompt: "create a plugin")
        turn.applyStreamChunk(status: .complete, chunk: "Installed ")
        turn.applyStreamChunk(status: .complete, chunk: "daily-news.")
        #expect(turn.response == "Installed daily-news.")
    }

    @Test func pluginTestChunkSetsStructuredReport() {
        let report = PluginInvokePresentation.TestReport(
            heading: "Testing new plugin daily-news…",
            body: "successful",
            kind: .programmatic
        )
        var turn = ChatTurn(prompt: "build it")
        turn.applyStreamChunk(status: .complete, chunk: PluginInvokePresentation.encodeTestReport(report))
        #expect(turn.pluginTest?.heading == report.heading)
        #expect(turn.pluginTest?.kind == .programmatic)
        #expect(turn.response == "successful")
    }
}
