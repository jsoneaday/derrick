import HostUI
import Testing

@MainActor
@Suite struct HostUICompletionStatusTests {
    @Test func mapsWireStatusToEnglishLabel() {
        #expect(HostUICompletionStatus.label(status: "thinking") == "Thinking")
        #expect(HostUICompletionStatus.label(status: "tool_call") == "Tool Call")
        #expect(HostUICompletionStatus.label(status: "Working…") == "Working…")
    }

    @Test func appendsToolNameWhenPresent() {
        #expect(HostUICompletionStatus.label(status: "thinking", toolName: "read") == "Thinking read")
        #expect(HostUICompletionStatus.label(status: "thinking", toolName: "") == "Thinking")
        #expect(HostUICompletionStatus.label(status: "thinking", toolName: nil) == "Thinking")
    }
}
