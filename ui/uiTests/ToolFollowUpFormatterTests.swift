import Foundation
import MemorySystem
import Structure
import Testing
@testable import ui

@Suite struct ToolFollowUpFormatterTests {
    @Test func capsLongTextWithMarker() {
        let long = String(repeating: "a", count: 100)
        let capped = ToolFollowUpFormatter.cap(long, maxChars: 40)
        #expect(capped.hasSuffix("\n…[truncated]…"))
        #expect(capped.hasPrefix(String(repeating: "a", count: 40)))
        #expect(ToolFollowUpFormatter.cap("short", maxChars: 40) == "short")
    }

    @Test func formatsUnifiedOutcomeWithoutInternalMetrics() throws {
        let outcome = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .text, value: "HELLO_WORLD"),
            metrics: ToolExecutionOutcome.Metrics(
                reviewerMS: 4_000,
                totalMS: 4_300,
                scriptCharCount: 999
            )
        ).encodedJSON()
        let slim = ToolFollowUpFormatter.slim(toolName: "script_exec", rawResult: outcome, stdoutCap: 4_000)
        #expect(slim.contains("tool: script_exec"))
        #expect(slim.contains("status: completed"))
        #expect(slim.contains("stage: none"))
        #expect(slim.contains("output format: text"))
        #expect(slim.contains("HELLO_WORLD"))
        #expect(!slim.contains("reviewerMS"))
        #expect(!slim.contains("scriptCharCount"))
    }

    @Test func capsUnifiedOutcomeOutput() throws {
        let big = String(repeating: "x", count: 6_000)
        let json = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .text, value: big)
        ).encodedJSON()
        let slim = ToolFollowUpFormatter.slim(toolName: "script_exec", rawResult: json, stdoutCap: 100)
        #expect(slim.contains("…[truncated]…"))
        #expect(slim.count < 6_000)
    }

    @Test func includesUnifiedDiagnosticsAlongsidePartialOutput() throws {
        let json = try ToolExecutionOutcome.failure(
            stage: .execution,
            diagnostics: [
                ToolExecutionOutcome.Diagnostic(
                    code: "script_failed",
                    message: "The terminal result did not contain the requested fields."
                )
            ]
        ).encodedJSON()
        let slim = ToolFollowUpFormatter.slim(toolName: "script_exec", rawResult: json)
        #expect(slim.contains("stage: execution"))
        #expect(slim.contains("diagnostics:"))
        #expect(slim.contains("The terminal result did not contain the requested fields."))
    }

    @Test func appendsFailureDetailsWhenFinalResponseOmitsThem() throws {
        let json = try ToolExecutionOutcome.failure(
            status: .blocked,
            stage: .review,
            diagnostics: [
                ToolExecutionOutcome.Diagnostic(
                    code: "functional_mismatch",
                    message: "The script returned raw HTML instead of extracting the requested fields."
                )
            ]
        ).encodedJSON()
        let records = [
            ToolCallRecord(
                name: "script_exec",
                arguments: [:],
                result: json
            )
        ]
        let response = ToolFollowUpFormatter.appendingFailureDetails(
            to: "I could not complete the request.",
            records: records
        )
        #expect(response.contains("Tool failure details:"))
        #expect(response.contains("Failure stage: review"))
        #expect(response.contains("The script returned raw HTML"))
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

    @Test func slimToolResultsUsesRecordsAndKeepsFullResultElsewhere() throws {
        let full = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .text, value: "answer-42"),
            metrics: ToolExecutionOutcome.Metrics(
                staticValidateMS: 1,
                reviewerMS: 1,
                ensureMS: 1,
                execMS: 1,
                totalMS: 4,
                scriptCharCount: 1,
                scriptLineCount: 1
            )
        ).encodedJSON()
        let record = ToolCallRecord(
            name: "script_exec",
            arguments: ["script": "print('answer-42')\n"],
            result: full
        )
        // Full outcome remains on the record for memory/debug consumers.
        #expect(record.result?.contains("\"metrics\"") == true)

        let slim = ToolFollowUpFormatter.slimToolResults(records: [record])
        #expect(slim.contains("answer-42"))
        #expect(!slim.contains("reviewerMS"))

        let request = ToolFollowUpFormatter.slimToolRequestLine(records: [record])
        #expect(request.contains("script_exec"))
        #expect(!request.contains("print('answer-42')"))
    }

    @Test func opaqueResultIsCapped() {
        let noise = String(repeating: "z", count: 50)
        let slim = ToolFollowUpFormatter.slim(toolName: "other_tool", rawResult: noise, stdoutCap: 20)
        #expect(slim.contains("…[truncated]…"))
        #expect(slim.contains("tool: other_tool"))
    }
}
