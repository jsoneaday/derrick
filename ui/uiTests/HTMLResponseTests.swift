import Foundation
import Structure
import Testing
@testable import ui

@Suite struct HTMLResponseTests {
    @Test func sanitizerPreservesSafeLinksAndRemovesUnsafeMarkup() {
        let source = #"""
        <div onclick="alert('x')">
          <strong>Headline</strong>
          <a href="https://example.com/story">Read the story</a>
          <a href="javascript:alert('x')">Unsafe</a>
          <script>alert("x")</script>
        </div>
        """#

        let sanitized = HTMLSanitizer.sanitize(source)

        #expect(sanitized.contains("<strong>Headline</strong>"))
        #expect(sanitized.contains(#"<a href="https://example.com/story">Read the story</a>"#))
        #expect(!sanitized.contains("onclick"))
        #expect(!sanitized.contains("<script"))
        #expect(!sanitized.contains("javascript:"))
    }

    @Test func extractorReadsHTMLResultEnvelope() {
        let raw = #"[{"verb":"result.emit","title":"News","html":"<p>Headline</p>"}]"#

        let payload = PluginHTMLResultExtractor.payload(from: raw)

        #expect(payload?.title == "News")
        #expect(payload?.html == "<p>Headline</p>")
    }

    @Test func extractorUnwrapsMarkdownResultEnvelope() {
        let raw = #"""
        [{"verb":"result.emit","title":"News","content":"## Headline\n\n[Read more](https://example.com)"}]
        """#

        let payload = PluginResultExtractor.payload(from: raw)

        #expect(payload?.title == "News")
        #expect(payload?.body == "## Headline\n\n[Read more](https://example.com)")
        #expect(payload?.format == .text)
        #expect(payload?.displayText.contains("\"verb\"") == false)
    }

    @Test func extractorHandlesEscapedURLsFromPluginOutput() {
        let raw = #"""
        [{"summary":"Latest headlines","verb":"result.emit","content":"## Digest Source: [National Review](https:\/\/www.nationalreview.com\/feed\/) 1. [Headline](https:\/\/www.nationalreview.com\/story\/) <\/i>"}]
        """#

        let payload = PluginResultExtractor.payload(from: raw)

        #expect(payload?.body.contains("National Review") == true)
        #expect(payload?.body.contains("\"verb\"") == false)
        #expect(payload?.format == .text)
    }

    @Test func extractorUnwrapsDoubleEncodedPluginOutput() {
        let raw = #"""
        [{\"verb\":\"result.emit\",\"content\":\"## Digest\\n\\n[Source](https:\\/\\/example.com) <\\/i>\"}]
        """#

        let payload = PluginResultExtractor.payload(from: raw)

        #expect(payload?.body.contains("## Digest") == true)
        #expect(payload?.body.contains("\"verb\"") == false)
        #expect(payload?.format == .text)
    }

    @Test func extractorRepairsRawNewlinesInsideJSONContent() {
        let raw = """
        [{"verb":"result.emit","content":"## Digest
        [Source](https://example.com)"}]
        """

        let payload = PluginResultExtractor.payload(from: raw)

        #expect(payload?.body.contains("## Digest") == true)
        #expect(payload?.body.contains("[Source](https://example.com)") == true)
        #expect(payload?.format == .text)
    }

    @Test func extractorRepairsNewlinesAndEscapedURLsTogether() {
        let raw = #"""
        [{"verb":"result.emit","content":"## Digest
        Source: [National Review](https:\/\/www.nationalreview.com\/feed\/) <\/i>"}]
        """#

        let payload = PluginResultExtractor.payload(from: raw)

        #expect(payload?.body.contains("## Digest") == true)
        #expect(payload?.body.contains("National Review") == true)
        #expect(payload?.body.contains("</i>") == false)
        #expect(payload?.format == .text)
    }

    @Test func extractorUnwrapsHTMLFromUnifiedScriptOutcome() throws {
        let raw = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(
                format: .text,
                value: "<p>Headline</p>"
            )
        ).encodedJSON()

        let payload = PluginHTMLResultExtractor.payload(from: raw)

        #expect(payload?.title == nil)
        #expect(payload?.html == "<p>Headline</p>")
    }

    @Test func extractorUnwrapsUnifiedPluginOutcome() throws {
        let nested = #"[{"verb":"result.emit","title":"News","html":"<p>Headline</p>"}]"#
        let outcome = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: nested)
        ).encodedJSON()

        let payload = PluginHTMLResultExtractor.payload(from: outcome)

        #expect(payload?.title == "News")
        #expect(payload?.html == "<p>Headline</p>")
    }

    @Test func extractorPresentsUnifiedFailureDiagnostics() throws {
        let outcome = try ToolExecutionOutcome.failure(
            status: .blocked,
            stage: .review,
            diagnostics: [
                ToolExecutionOutcome.Diagnostic(
                    code: "functional_mismatch",
                    message: "The result did not satisfy the request."
                )
            ]
        ).encodedJSON()

        let payload = PluginResultExtractor.payload(from: outcome)

        #expect(payload?.body.contains("review") == true)
        #expect(payload?.body.contains("did not satisfy the request") == true)
        #expect(payload?.format == .text)
    }

    @Test func extractorUnwrapsNestedOutputValue() throws {
        let nested = #"{"text":"News digest.\n\n1. Headline"}"#
        let data = try JSONSerialization.data(
            withJSONObject: ["output": ["value": nested]],
            options: [.sortedKeys]
        )
        let raw = String(decoding: data, as: UTF8.self)

        let payload = PluginResultExtractor.payload(from: raw)

        #expect(payload?.body.contains("News digest.") == true)
        #expect(payload?.body.contains("1. Headline") == true)
        #expect(payload?.body.contains("\"output\"") == false)
        #expect(payload?.format == .text)
    }

    @Test func extractorRepairsNestedEscapedLineContinuations() {
        let nested = "[{\"text\":\"## News digest\\\n\\\nThis digest contains only source text.\"}]"
        let escapedNested = nested.replacingOccurrences(of: "\"", with: "\\\"")
        var raw = #"{"status":"completed","stage":"none","output":{"format":"json","value":""#
        raw += escapedNested
        raw += #""},"diagnostics":[]}"#

        let payload = PluginResultExtractor.payload(from: raw)

        #expect(payload?.body.contains("## News digest") == true)
        #expect(payload?.body.contains("This digest contains only source text.") == true)
        #expect(payload?.body.contains("\\") == false)
        #expect(payload?.body.contains("\"output\"") == false)
    }
}
