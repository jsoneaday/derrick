import Foundation
import Testing
@testable import Structure

@Suite struct PluginLiveAcceptanceTests {
    @Test func fixtureOnlyScriptIsNotALiveTest() {
        let input = Data(#"{"hops":[{"kind":"http_results","http_results":[{"request_id":"sync_threads_page_1","status":200,"body":"{\"ok\":true}"}]}]}"#.utf8)
        let problem = PluginLiveAcceptance.problem(
            testInput: input,
            stdout: #"[{"verb":"result.emit","threads":[]}]"#,
            stderr: "",
            exitCode: 0,
            messagingOps: ["sync_threads"]
        )
        #expect(problem?.contains("not a test") == true)
    }

    @Test func liveSyncWithoutThreadsFails() {
        let input = Data(#"{"hops":[{"kind":"manual","params":{"messaging_op":"sync_threads"}}]}"#.utf8)
        let problem = PluginLiveAcceptance.problem(
            testInput: input,
            stdout: #"[{"verb":"result.emit","title":"Slack","summary":"Slack request failed: missing_scope"}]"#,
            stderr: "",
            exitCode: 0,
            messagingOps: ["sync_threads"]
        )
        #expect(problem?.contains("did not return threads") == true)
    }

    @Test func liveSyncWithThreadsPassesShape() {
        let input = Data(#"{"hops":[{"kind":"manual","params":{"messaging_op":"sync_threads"}}]}"#.utf8)
        let problem = PluginLiveAcceptance.problem(
            testInput: input,
            stdout: #"[{"verb":"result.emit","threads":[{"vendor_thread_id":"C1","title":"general"}]}]"#,
            stderr: "",
            exitCode: 0,
            messagingOps: ["sync_threads"]
        )
        #expect(problem == nil)
    }

    @Test func newsReaderDirectionsAreNotConnectorDirections() {
        let text = PluginAcceptanceDirections.builderText(forUserGoal: "Read tech news headlines")
        #expect(text.contains("news reader"))
        #expect(!text.contains("sync_threads"))
    }
}
