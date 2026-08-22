import Foundation
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
}
