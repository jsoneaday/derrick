import Foundation
import MemorySystem
import Testing
@testable import ui

/// Empirical size check: old follow-up (full tool JSON + full script args) vs slim agent context.
/// Mirrors the React live-fetch scale (~12k user chars / ~5k prompt tokens on R2).
@Suite struct ToolFollowUpMeasureTests {
    @Test func reactScaleFollowUpCharReduction() {
        let fixture = ReactScaleToolFixture.make()
        let record = ToolCallRecord(
            name: "python_script_exec",
            arguments: fixture.arguments,
            result: fixture.fullResultJSON
        )

        // --- Before: what the pipeline used to inject into R2 ---
        let oldRequestLine = "\(record.name): \(record.arguments)"
        let oldResultBody = "\(record.name): \(record.result ?? "")"
        let oldFollowUp = Self.buildLegacyFollowUpPrompt(
            originalPrompt: ReactScaleToolFixture.userPrompt,
            assistantToolRequest: oldRequestLine,
            toolResultSummary: oldResultBody
        )

        // --- After: current slim path ---
        let slimRequest = ToolFollowUpFormatter.slimToolRequestLine(records: [record])
        let slimResult = ToolFollowUpFormatter.slimToolResults(records: [record])
        let newFollowUp = Self.buildLegacyFollowUpPrompt(
            originalPrompt: ReactScaleToolFixture.userPrompt,
            assistantToolRequest: slimRequest,
            toolResultSummary: slimResult
        )

        let fullResultChars = (record.result ?? "").count
        let oldFollowUpChars = oldFollowUp.count
        let newFollowUpChars = newFollowUp.count
        let slimResultChars = slimResult.count
        let oldRequestChars = oldRequestLine.count
        let slimRequestChars = slimRequest.count

        // Rough token estimate (~4 chars/token) for comparison to prior ~5.3k prompt tokens.
        let oldTokensEst = max(1, oldFollowUpChars / 4)
        let newTokensEst = max(1, newFollowUpChars / 4)
        let reductionPct = 100.0 * (1.0 - Double(newFollowUpChars) / Double(max(1, oldFollowUpChars)))

        let report = """
        [FOLLOWUP_MEASURE] react_scale
          full_result_chars=\(fullResultChars)
          old_request_chars=\(oldRequestChars) slim_request_chars=\(slimRequestChars)
          old_result_body_chars=\(oldResultBody.count) slim_result_chars=\(slimResultChars)
          old_followup_chars=\(oldFollowUpChars) new_followup_chars=\(newFollowUpChars)
          old_tokens_est=\(oldTokensEst) new_tokens_est=\(newTokensEst)
          reduction_pct=\(String(format: "%.1f", reductionPct))
          slim_has_reviewer=\(slimResult.contains("reviewerAssessment"))
          slim_has_phaseTiming=\(slimResult.contains("phaseTiming"))
          slim_has_wiped=\(slimResult.contains("wiped /tmp"))
          slim_has_answer_marker=\(slimResult.contains(ReactScaleToolFixture.answerMarker))
          full_still_on_record=\((record.result ?? "").contains("reviewerAssessment"))
        """
        // Visible in xcodebuild test output for the measurement item.
        print(report)

        // Sanity: fixture is in the ballpark of the original React dump (~12k user side).
        #expect(fullResultChars >= 8_000, "fixture full result should be large like the live dump")
        #expect(oldFollowUpChars >= 10_000, "legacy follow-up should be ~12k-scale")

        // Slim must drop control-plane fields and wrapper noise.
        #expect(!slimResult.contains("reviewerAssessment"))
        #expect(!slimResult.contains("phaseTiming"))
        #expect(!slimResult.contains("wiped /tmp"))
        #expect(slimResult.contains(ReactScaleToolFixture.answerMarker))
        #expect((record.result ?? "").contains("reviewerAssessment"), "debug/memory keep full JSON")

        // Material reduction (target: cut most of the dump; allow headroom for prompt chrome + capped stdout).
        #expect(newFollowUpChars < oldFollowUpChars / 2, "follow-up should shrink by >50%")
        #expect(slimResultChars <= ToolFollowUpFormatter.defaultStdoutCap + 500, "stdout path is capped ~4k + headers")
        #expect(slimRequestChars < 400, "script body must not reappear in request line")
        #expect(!slimRequest.contains("import urllib"), "full script must not be in slim request")
    }

    /// Same template as ConversationPipelinePolicy.buildFollowUpPrompt (kept local so measure stays stable).
    private static func buildLegacyFollowUpPrompt(
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
        import urllib.request
        import re
        # Simulated agent research script for React live fetch (size similar to real runs).
        url = "https://reactjs.org"
        html = urllib.request.urlopen(url, timeout=30).read().decode("utf-8", errors="ignore")
        print("fetched", len(html))
        # lots of parsing boilerplate
        \(String(repeating: "# pad line for realistic script size\\n", count: 80))
        print("\(answerMarker)")
        for i in range(20):
            print(f"headline-{i}")
        """

        // ~6–8k of scraped HTML-ish noise that used to ride into R2 via full JSON stdout.
        let scraped = String(repeating: "<div class=\"news\">React release filler content \(UUID().uuidString.prefix(8)). </div>\n", count: 120)
        // Useful facts first (what a good script prints); bulk scrape after — slim caps at 4k.
        let wrapperStdout = """
        [python_script_exec] wiped /tmp and /var/tmp
        [python_script_exec] verified baseline package: requests -> requests
        [python_script_exec] verified baseline package: urllib3 -> urllib3
        \(answerMarker)
        headline-0
        headline-1
        headline-2
        fetched \(scraped.utf8.count)
        \(scraped)
        """

        let result: [String: Any] = [
            "status": "completed",
            "decision": "allow",
            "failureStage": "none",
            "verifier": "static-check-v1",
            "validationFindings": [] as [String],
            "reviewerAssessment": [
                "alignedWithRequest": true,
                "confidence": 0.91,
                "suggestedAction": "allow",
                "concerns": [
                    "Script performs outbound HTTP to reactjs.org",
                    "Uses urllib without explicit rate limiting",
                    "Parses HTML which may include third-party content"
                ],
                "summary": "Allow network read of React docs for version lookup."
            ] as [String: Any],
            "stdout": wrapperStdout,
            "stderr": "",
            "exitCode": 0,
            "timedOut": false,
            "durationMS": 4821,
            "phaseTiming": [
                "staticValidateMS": 12,
                "reviewerMS": 4100,
                "ensureMS": 180,
                "execMS": 1500,
                "totalMS": 5800,
                "scriptCharCount": script.count,
                "scriptLineCount": script.split(separator: "\n").count,
                "wrapperCharCount": 9200
            ] as [String: Any]
        ]

        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let json = String(decoding: data, as: UTF8.self)

        let arguments: [String: String] = [
            "mode": "readonly",
            "description": "Fetch live React version",
            "reason": "User asked for current React version from the web",
            "script": script,
            "allow_network": "true",
            "python_packages": "[]",
            "timeout_seconds": "60"
        ]
        return (arguments, json)
    }
}
