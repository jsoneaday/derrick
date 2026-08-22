import Foundation
import Testing
@testable import Lib

@Suite struct ToolArgumentsJSONTests {
    @Test func emptyObjectIsValidArguments() throws {
        let args = try parseToolArgumentsObject("{}")
        #expect(args.isEmpty)
        let blank = try parseToolArgumentsObject("   ")
        #expect(blank.isEmpty)
    }

    @Test func parsesValidArguments() throws {
        let json = #"{"mode":"readonly","allow_network":true,"script":"import Foundation\nprint(1)"}"#
        let args = try parseToolArgumentsObject(json)
        #expect(args["mode"] != nil)
        #expect(args["script"] != nil)
    }

    @Test func repairsBareQuotesInsideSwiftSource() throws {
        let broken = brokenArguments(
            script: "import Foundation\nlet selector = \"div[data-component-type=\\\"s-search-result\\\"]\"\nprint(selector)"
        )
        #expect(strictParse(broken) == false)

        let args = try parseToolArgumentsObject(broken)
        guard case .string(let script)? = args["script"] else {
            Issue.record("expected recovered script")
            return
        }
        #expect(script.contains("s-search-result"))
        #expect(args["mode"] != nil)
        #expect(args["allow_network"] != nil)
    }

    @Test func repairsFullLengthSwiftScript() throws {
        let script = [
            "import Foundation",
            "let url = \"https://www.amazon.com/s?k=bicycle\"",
            "let title = \"Bicycle\"",
            "let selector = \"div[data-component-type=\\\"s-search-result\\\"]\"",
            "let result = \"{\\\"title\\\":\\\"Bicycle\\\",\\\"url\\\":\\\"https://www.amazon.com/s?k=bicycle\\\"}\"",
            "print(result)"
        ].joined(separator: "\n")

        let broken = brokenArguments(script: script, includeDependencies: true)
        #expect(strictParse(broken) == false)

        let args = try parseToolArgumentsObject(broken)
        guard case .string(let recovered)? = args["script"] else {
            Issue.record("expected script")
            return
        }
        #expect(recovered.contains("amazon.com"))
        #expect(recovered.contains("s-search-result"))
        #expect(recovered.contains("print(result)"))
        #expect(args["dependencies"] != nil)
        #expect(args["timeout_seconds"] != nil)
        #expect(args["description"] != nil)
    }

    @Test func repairsSwiftQuotesInsideSource() throws {
        let broken = brokenArguments(
            script: "import Foundation\nlet value = \"\\$5\"\nprint(value)"
        )
        #expect(strictParse(broken) == false)

        let args = try parseToolArgumentsObject(broken)
        #expect(args["script"] != nil)
        #expect(args["mode"] != nil)
    }

    @Test func validPayloadUnchangedRoundTrip() throws {
        let script = "import Foundation\nprint(\"hello\")"
        let payload: [String: Any] = [
            "mode": "readonly",
            "allow_network": true,
            "script": script
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let valid = String(data: data, encoding: .utf8)!
        #expect(strictParse(valid) == true)

        let args = try parseToolArgumentsObject(valid)
        guard case .string(let s)? = args["script"] else {
            Issue.record("expected script")
            return
        }
        #expect(s == script)
    }

    @Test func productionLogStyleUnderEscapedSwiftQuotes() throws {
        let broken = brokenArguments(
            script: "import Foundation\nlet selector = \"div[data-component-type=\\\"s-search-result\\\"]\"\nprint(selector)",
            includeDependencies: true
        )
        #expect(strictParse(broken) == false)
        let args = try parseToolArgumentsObject(broken)
        guard case .string(let script)? = args["script"] else {
            Issue.record("expected script")
            return
        }
        #expect(script.contains("s-search-result"))
        #expect(script.contains("Foundation"))
    }

    @Test func repairsNestedJobsCreateWithRealNewlinesInScript() throws {
        // Simulates jobs_create after outer AgentResponse decode: real newlines in nested script.
        var broken = #"{"run_after_seconds":5,"tool_name":"script_exec","tool_arguments":{"mode":"readonly","script":""#
        broken += "import Foundation\nprint(42)"
        broken += #""},"wake_after":true,"wake_prompt":"Return the deterministic number in chat"}"#
        #expect(strictParse(broken) == false)

        let args = try parseToolArgumentsObject(broken)
        #expect(args["tool_name"] != nil)
        #expect(args["tool_arguments"] != nil)
        #expect(args["run_after_seconds"] != nil)
        if case .object(let ta)? = args["tool_arguments"], case .string(let script)? = ta["script"] {
            #expect(script.contains("print(42)"))
            #expect(script.contains("print"))
        } else {
            Issue.record("expected nested tool_arguments.script")
        }
    }

    @Test func validNestedJobsCreateParses() throws {
        let json = #"{"run_after_seconds":5,"tool_name":"script_exec","tool_arguments":{"mode":"readonly","script":"import Foundation\nprint(42)"},"wake_after":true,"wake_prompt":"Return the deterministic number in chat"}"#
        let args = try parseToolArgumentsObject(json)
        #expect(args["tool_arguments"] != nil)
    }

    @Test func repairsTruncatedJobsCreateWakePrompt() throws {
        // Production failure shape: stream cut mid wake_prompt (prefix ~200 of log).
        let trunc = #"{"run_after_seconds":5,"tool_name":"script_exec","tool_arguments":{"mode":"readonly","script":"import Foundation\nprint(42)"},"wake_after":true,"wake_prompt":"Return the det"#
        #expect(strictParse(trunc) == false)

        let args = try parseToolArgumentsObject(trunc)
        #expect(args["tool_name"] != nil)
        #expect(args["tool_arguments"] != nil)
        #expect(args["run_after_seconds"] != nil)
        if case .object(let ta)? = args["tool_arguments"], case .string(let script)? = ta["script"] {
            #expect(script.contains("print(42)"))
        } else {
            Issue.record("expected nested tool_arguments.script after truncate repair")
        }
    }

    @Test func stripsSpuriousTrailingBraceFromNestedToolArguments() throws {
        let valid = #"{"run_after_seconds":9,"tool_name":"script_exec","tool_arguments":{"mode":"readonly","script":"import Foundation\nprint(\"scheduled test failure\")"},"wake_after":true,"wake_prompt":"Report the scheduled script failure result."}"#
        let corrupted = valid + "}"
        #expect(strictParse(corrupted) == false)
        let args = try parseToolArgumentsObject(corrupted)
        #expect(args["tool_name"] != nil)
    }

    @Test func repairsScheduledTestFailureScriptWithRealNewlines() throws {
        var broken = #"{"run_after_seconds":9,"tool_name":"script_exec","tool_arguments":{"mode":"readonly","script":""#
        broken += "import Foundation\nprint(\"scheduled test failure\")"
        broken += #""},"wake_after":true,"wake_prompt":"Report the scheduled script failure result."}"#
        #expect(strictParse(broken) == false)
        let args = try parseToolArgumentsObject(broken)
        #expect(args["tool_name"] != nil)
        if case .object(let ta)? = args["tool_arguments"], case .string(let script)? = ta["script"] {
            #expect(script.contains("scheduled test failure"))
            #expect(script.contains("print"))
        } else {
            Issue.record("expected nested tool_arguments.script")
        }
    }

    @Test func repairsTruncatedNestedScriptWithRealNewlines() throws {
        var trunc = #"{"run_after_seconds":5,"tool_name":"script_exec","tool_arguments":{"mode":"readonly","script":""#
        trunc += "import Foundation\nprint(42)"
        // cut before closing script / rest of object
        #expect(strictParse(trunc) == false)
        let args = try parseToolArgumentsObject(trunc)
        #expect(args["tool_name"] != nil)
        if case .object(let ta)? = args["tool_arguments"], case .string(let script)? = ta["script"] {
            #expect(script.contains("import Foundation"))
        } else {
            Issue.record("expected recovered nested script")
        }
    }

    /// Build invalid tool-arguments JSON: `script` contains raw `"` and real newlines.
    private func brokenArguments(script: String, includeDependencies: Bool = false) -> String {
        var s = #"{"mode":"readonly","allow_network":true,"script":""#
        s += script
        s += "\""
        s += #","timeout_seconds":120"#
        if includeDependencies {
            s += #","dependencies":{"Foundation":"system"}"#
            // Use regular strings carefully so closing quotes are real content.
            s += ",\"description\":\"Parse a deterministic result\""
            s += ",\"reason\":\"User requested structured output\""
        }
        s += "}"
        return s
    }

    private func strictParse(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return false
        }
        return true
    }
}
