import Foundation
import MemorySystem
import ServiceContracts
import Testing
@testable import ui

/// Empirical size check for the common tool outcome versus the slim agent context.
@Suite struct ToolFollowUpMeasureTests {
    @Test func reactScaleFollowUpCharReduction() {
        let fixture = ReactScaleToolFixture.make()
        let record = ToolCallRecord(
            name: "script_exec",
            arguments: fixture.arguments,
            result: fixture.fullResultJSON
        )

        // Full request/result sizes are retained for comparison.
        let oldRequestLine = "\(record.name): \(record.arguments)"
        let oldResultBody = "\(record.name): \(record.result ?? "")"
        let fullFollowUp = Self.buildFollowUpPrompt(
            originalPrompt: ReactScaleToolFixture.userPrompt,
            assistantToolRequest: oldRequestLine,
            toolResultSummary: oldResultBody
        )

        let slimRequest = ToolFollowUpFormatter.slimToolRequestLine(records: [record])
        let slimResult = ToolFollowUpFormatter.slimToolResults(records: [record])
        let slimFollowUp = Self.buildFollowUpPrompt(
            originalPrompt: ReactScaleToolFixture.userPrompt,
            assistantToolRequest: slimRequest,
            toolResultSummary: slimResult
        )

        let fullResultChars = (record.result ?? "").count
        let fullFollowUpChars = fullFollowUp.count
        let slimFollowUpChars = slimFollowUp.count
        let slimResultChars = slimResult.count
        let oldRequestChars = oldRequestLine.count
        let slimRequestChars = slimRequest.count

        // Rough token estimate (~4 chars/token) for comparison to prior ~5.3k prompt tokens.
        let fullTokensEst = max(1, fullFollowUpChars / 4)
        let slimTokensEst = max(1, slimFollowUpChars / 4)
        let reductionPct = 100.0 * (1.0 - Double(slimFollowUpChars) / Double(max(1, fullFollowUpChars)))

        let report = """
        [FOLLOWUP_MEASURE] react_scale
          full_result_chars=\(fullResultChars)
          old_request_chars=\(oldRequestChars) slim_request_chars=\(slimRequestChars)
          full_result_body_chars=\(oldResultBody.count) slim_result_chars=\(slimResultChars)
          full_followup_chars=\(fullFollowUpChars) slim_followup_chars=\(slimFollowUpChars)
          full_tokens_est=\(fullTokensEst) slim_tokens_est=\(slimTokensEst)
          reduction_pct=\(String(format: "%.1f", reductionPct))
          slim_has_metrics=\(slimResult.contains("metrics"))
          slim_has_answer_marker=\(slimResult.contains(ReactScaleToolFixture.answerMarker))
          full_still_on_record=\((record.result ?? "").contains("\"metrics\""))
        """
        // Visible in xcodebuild test output for the measurement item.
        print(report)

        // Sanity: the fixture is large enough to exercise the cap.
        #expect(fullResultChars >= 8_000, "fixture full result should be large like the live dump")
        #expect(fullFollowUpChars >= 10_000, "full follow-up should be large enough for comparison")

        // Slim must omit internal metrics while keeping the useful output.
        #expect(!slimResult.contains("metrics"))
        #expect(slimResult.contains(ReactScaleToolFixture.answerMarker))
        #expect((record.result ?? "").contains("\"metrics\""), "debug/memory keep full JSON")

        // Material reduction (target: cut most of the dump; allow headroom for prompt chrome + capped stdout).
        #expect(slimFollowUpChars < fullFollowUpChars / 2, "follow-up should shrink by >50%")
        #expect(slimResultChars <= ToolFollowUpFormatter.defaultStdoutCap + 500, "stdout path is capped ~4k + headers")
        #expect(slimRequestChars < 400, "script body must not reappear in request line")
        #expect(!slimRequest.contains("import Foundation"), "full script must not be in slim request")
    }

    /// Same template as ConversationPipelinePolicy.buildFollowUpPrompt (kept local so measure stays stable).
    private static func buildFollowUpPrompt(
        originalPrompt: String,
        assistantToolRequest: String,
        toolResultSummary: String
    ) -> String {
        """
        Original user prompt:
        \(originalPrompt)

        You requested the following tool call:
        \(assistantToolRequest)

        Tool execution result:
        \(toolResultSummary)

        Produce the final user-facing response using the tool execution result as authoritative.
        """
    }
}

private enum ReactScaleToolFixture {
    static let answerMarker = "REACT_VERSION_LIVE=19.x-measure"

    static let userPrompt = """
    Look up the current React version from the live web and summarize recent release notes briefly.
    """

    static func make() -> (arguments: [String: String], fullResultJSON: String) {
        let script = """
        import Foundation
        let input = FileHandle.standardInput.readDataToEndOfFile()
        _ = input
        print("\(answerMarker)")
        \(String(repeating: "// deterministic parsing helper padding\\n", count: 80))
        """

        // Large source-grounded output exercises the common output cap.
        let scraped = String(repeating: "React release detail. ", count: 500)
        let wrapperStdout = """
        \(answerMarker)
        \(scraped)
        """

        let json = try! ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .text, value: wrapperStdout),
            metrics: ToolExecutionOutcome.Metrics(
                staticValidateMS: 12,
                reviewerMS: 4_100,
                ensureMS: 180,
                execMS: 1_500,
                totalMS: 5_800,
                scriptCharCount: script.count,
                scriptLineCount: script.split(separator: "\n").count
            )
        ).encodedJSON()

        let arguments: [String: String] = [
            "mode": "readonly",
            "description": "Fetch live React version",
            "reason": "User asked for current React version from the web",
            "script": script,
            "user_prompt": userPrompt,
            "allow_network": "true",
            "dependencies": "{}",
            "timeout_seconds": "60"
        ]
        return (arguments, json)
    }
}
