import Foundation
import LLMAgentClient
import Testing
@testable import ui

@Suite struct ChatTurnStreamingTests {
    @Test func thinkingReplacesSnapshotInsteadOfAppendingPrefixes() {
        var turn = ChatTurn(prompt: "write a script")
        turn.applyStreamChunk(status: .thinking, chunk: "I'll start")
        turn.applyStreamChunk(status: .thinking, chunk: "I'll start writing a script")
        turn.applyStreamChunk(status: .thinking, chunk: "I'll start writing a script.")
        #expect(turn.thought == "I'll start writing a script.")
        #expect(!turn.thought.contains("I'll startI'll start"))
        #expect(turn.response.isEmpty)
    }

    @Test func laterThoughtReplacesPriorThought() {
        var turn = ChatTurn(prompt: "summarize headlines")
        turn.applyStreamChunk(status: .thinking, chunk: "I'll start writing a script")
        turn.applyStreamChunk(status: .thinking, chunk: "Call script_exec next.")
        #expect(turn.thought == "Call script_exec next.")
    }

    @Test func completeStillAppendsAnswerDeltas() {
        var turn = ChatTurn(prompt: "run it")
        turn.applyStreamChunk(status: .complete, chunk: "Done ")
        turn.applyStreamChunk(status: .complete, chunk: "successfully.")
        #expect(turn.response == "Done successfully.")
    }

    @Test func progressToolChunkAppendsWithoutEndingStatus() {
        var turn = ChatTurn(prompt: "create a plugin")
        turn.applyStreamChunk(
            status: .toolCall,
            chunk: "Drafting plugin…",
            isProgress: true
        )

        #expect(turn.response == "Drafting plugin…")
        #expect(turn.status == nil)
    }
}
