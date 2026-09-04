import Foundation
import ServiceContracts
import Testing
@testable import Plugin

@Suite struct ConnectorMessagingTests {
    @Test func hopBuilderSetsMessagingOperation() throws {
        let data = try ConnectorMessagingHopBuilder.inputData(operation: .syncThreads)
        let event = try JSONDecoder().decode(PluginHopEvent.self, from: data)
        #expect(event.kind == .manual)
        #expect(event.params?["messaging_op"]?.stringValue == "sync_threads")
    }

    @Test func sendHopUsesMessageInRoomKind() throws {
        let data = try ConnectorMessagingHopBuilder.inputData(
            operation: .sendMessage,
            params: [
                "vendor_thread_id": .string("C123"),
                "text": .string("hello"),
            ]
        )
        let event = try JSONDecoder().decode(PluginHopEvent.self, from: data)
        #expect(event.kind == .messageInRoom)
        #expect(event.params?["messaging_op"]?.stringValue == "send_message")
        #expect(event.params?["vendor_thread_id"]?.stringValue == "C123")
    }

    @Test func parserReadsThreadsMessagesAndSentMessage() throws {
        let envelopes = """
        [{"verb":"result.emit","threads":[{"vendor_thread_id":"C1","title":"#general"}],"messages":[{"vendor_thread_id":"C1","vendor_message_id":"1.0","direction":"inbound","sender":"alice","body":"hi","created_at":"1710000000.000100"}],"sent_message":{"vendor_message_id":"2.0","created_at":"1710000001.000100"}}]
        """
        let result = try ConnectorMessagingParser.parse(envelopeJSON: Data(envelopes.utf8))
        #expect(result.threads.count == 1)
        #expect(result.messages.count == 1)
        #expect(result.sentMessage?.vendorMessageID == "2.0")
    }

    @Test func parserReadsCompletedToolOutcome() throws {
        let envelopes = """
        [{"verb":"result.emit","threads":[{"vendor_thread_id":"C9","title":"#random"}]}]
        """
        let outcome = ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
        )
        let text = try outcome.encodedJSON()
        let result = try ConnectorMessagingParser.parse(toolOutcomeText: text)
        #expect(result.threads.first?.vendorThreadID == "C9")
    }

    @Test func parserSurfacesTerminalSummaryWhenSentMessageMissing() throws {
        let envelopes = """
        [{"verb":"result.emit","title":"Slack send failed","summary":"not_in_channel"}]
        """
        let outcome = ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
        )
        let text = try outcome.encodedJSON()
        let result = try ConnectorMessagingParser.parse(toolOutcomeText: text)
        #expect(throws: ConnectorMessagingError.self) {
            _ = try ConnectorMessagingParser.requireSentMessage(result)
        }
        do {
            _ = try ConnectorMessagingParser.requireSentMessage(result)
        } catch let error as ConnectorMessagingError {
            if case .pluginFailed(let detail) = error {
                #expect(detail.contains("not_in_channel"))
            } else {
                Issue.record("Expected pluginFailed, got \(error)")
            }
        }
    }

    @Test func parserAcceptsNumericSentMessageID() throws {
        let envelopes = """
        [{"verb":"result.emit","sent_message":{"vendor_message_id":1710000001.5,"created_at":"1710000001.5"}}]
        """
        let result = try ConnectorMessagingParser.parse(envelopeJSON: Data(envelopes.utf8))
        #expect(result.sentMessage?.vendorMessageID == "1710000001.5")
    }

    @Test func parserRejectsFailedToolOutcome() {
        let outcome = ToolExecutionOutcome.failure(
            stage: .execution,
            diagnostics: [
                ToolExecutionOutcome.Diagnostic(code: "plugin_process_failed", message: "boom")
            ]
        )
        let text = (try? outcome.encodedJSON()) ?? ""
        #expect(throws: ConnectorMessagingError.self) {
            _ = try ConnectorMessagingParser.parse(toolOutcomeText: text)
        }
    }
}
