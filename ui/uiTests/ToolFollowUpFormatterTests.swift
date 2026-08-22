import Foundation
import MemorySystem
import Testing
@testable import ui

@Suite struct ToolFollowUpFormatterTests {
    @Test func stripsScriptWrapperLinesFromStdout() {
        let raw = """
        [script_exec] wiped /tmp and /var/tmp
        [script_exec] Swift container ready
        real data line
        [TIME_METRIC] script_exec total_ms=1
        more data
        """
        let cleaned = ToolFollowUpFormatter.stripWrapperLines(from: raw)
        #expect(cleaned == "real data line\nmore data")
        #expect(!cleaned.contains("[script_exec]"))
        #expect(!cleaned.contains("[TIME_METRIC]"))
    }

    @Test func capsLongTextWithMarker() {
        let long = String(repeating: "a", count: 100)
        let capped = ToolFollowUpFormatter.cap(long, maxChars: 40)
        #expect(capped.hasSuffix("\n…[truncated]…"))
        #expect(capped.hasPrefix(String(repeating: "a", count: 40)))
        #expect(ToolFollowUpFormatter.cap("short", maxChars: 40) == "short")
    }

    @Test func slimsScriptJSONDroppingReviewerAndTiming() throws {
        let json = """
        {
          "status": "completed",
          "decision": "allow",
          "failureStage": "none",
          "verifier": "static-check-v1",
          "validationFindings": [],
          "reviewerAssessment": {
            "alignedWithRequest": true,
            "confidence": 0.9,
            "suggestedAction": "allow",
            "concerns": ["noise"],
            "summary": "ok"
          },
          "stdout": "[script_exec] wiped /tmp and /var/tmp\\nHELLO_WORLD\\n",
          "stderr": "",
          "exitCode": 0,
          "timedOut": false,
          "durationMS": 1234,
          "phaseTiming": {
            "staticValidateMS": 1,
            "reviewerMS": 4000,
            "ensureMS": 100,
            "execMS": 200,
            "totalMS": 4300,
            "scriptCharCount": 999,
            "scriptLineCount": 20,
            "wrapperCharCount": 5000
          }
        }
        """
        let slim = ToolFollowUpFormatter.slim(toolName: "script_exec", rawResult: json, stdoutCap: 4_000)
        #expect(slim.contains("tool: script_exec"))
        #expect(slim.contains("status: completed"))
        #expect(slim.contains("exitCode: 0"))
        #expect(slim.contains("timedOut: false"))
        #expect(slim.contains("HELLO_WORLD"))
        #expect(!slim.contains("wiped /tmp"))
        #expect(!slim.contains("reviewerAssessment"))
        #expect(!slim.contains("phaseTiming"))
        #expect(!slim.contains("static-check-v1"))
        #expect(!slim.contains("noise"))
        #expect(!slim.contains("durationMS"))
        #expect(!slim.contains("failureStage"))
    }

    @Test func capsStdoutInScriptSlimResult() {
        let big = String(repeating: "x", count: 6_000)
        let json = """
        {"status":"completed","stdout":"\(big)","stderr":"","exitCode":0,"timedOut":false,"failureStage":"none"}
        """
        let slim = ToolFollowUpFormatter.slim(toolName: "script_exec", rawResult: json, stdoutCap: 100)
        #expect(slim.contains("…[truncated]…"))
        #expect(slim.count < 6_000)
    }

    @Test func includesStderrWhenPresentAndStripsWrappers() {
        let json = """
        {
          "status": "failed",
          "failureStage": "execution",
          "stdout": "",
          "stderr": "[script_exec] Swift compiler error\\nplugin.swift:1:1: error: expected expression",
          "exitCode": 1,
          "timedOut": false
        }
        """
        let slim = ToolFollowUpFormatter.slim(toolName: "script_exec", rawResult: json)
        #expect(slim.contains("failureStage: execution"))
        #expect(slim.contains("stderr:"))
        #expect(slim.contains("expected expression"))
        #expect(!slim.contains("[script_exec] Swift compiler error"))
    }

    @Test func scriptRequestOmitsFullScriptBody() {
        let script = """
        import Foundation
        let input = FileHandle.standardInput.readDataToEndOfFile()
        print(input.count)
        """
        let line = ToolFollowUpFormatter.slimRequestDescription(
            name: "script_exec",
            arguments: [
                "allow_network": "true",
                "script": script,
                "dependencies": #"{"swiftpkg":"1.0.0"}"#
            ]
        )
        #expect(line.contains("script_exec"))
        #expect(line.contains("allow_network=true"))
        #expect(line.contains("script_lines="))
        #expect(line.contains("dependencies=unsupported"))
        #expect(!line.contains("import Foundation"))
        #expect(!line.contains("print(1)"))
    }

    @Test func slimToolResultsUsesRecordsAndKeepsFullResultElsewhere() {
        let full = #"{"status":"completed","stdout":"answer-42","stderr":"","exitCode":0,"timedOut":false,"failureStage":"none","reviewerAssessment":{"alignedWithRequest":true,"confidence":1,"suggestedAction":"allow","concerns":[],"summary":"ok"},"phaseTiming":{"staticValidateMS":1,"reviewerMS":1,"ensureMS":1,"execMS":1,"totalMS":4,"scriptCharCount":1,"scriptLineCount":1,"wrapperCharCount":1}}"#
        let record = ToolCallRecord(
            name: "script_exec",
            arguments: ["script": "print('answer-42')\n"],
            result: full
        )
        // Full result remains on the record for memory/debug consumers.
        #expect(record.result?.contains("reviewerAssessment") == true)
        #expect(record.result?.contains("phaseTiming") == true)

        let slim = ToolFollowUpFormatter.slimToolResults(records: [record])
        #expect(slim.contains("answer-42"))
        #expect(!slim.contains("reviewerAssessment"))
        #expect(!slim.contains("phaseTiming"))

        let request = ToolFollowUpFormatter.slimToolRequestLine(records: [record])
        #expect(request.contains("script_exec"))
        #expect(!request.contains("print('answer-42')"))
    }

    @Test func nonJSONResultIsStillStrippedAndCapped() {
        let noise = """
        [script_exec] wiped /tmp and /var/tmp
        \(String(repeating: "z", count: 50))
        """
        let slim = ToolFollowUpFormatter.slim(toolName: "other_tool", rawResult: noise, stdoutCap: 20)
        #expect(!slim.contains("[script_exec]"))
        #expect(slim.contains("…[truncated]…"))
        #expect(slim.contains("tool: other_tool"))
    }
}
