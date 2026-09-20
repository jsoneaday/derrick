import AppKit
import Structure
import SwiftUI

enum AgentProfileTokenColor {
    /// Darker than system green so `$profile` tokens stay readable on light bubbles.
    static let darkGreen = Color(red: 0.0, green: 0.42, blue: 0.18)
}

/// Selectable markdown used by landing chrome; HostUI message bubbles use `HostUIMarkdown`.
struct MessagingMarkdownText: View {
    let text: String
    var baseColor: Color = .primary
    var fontSize: CGFloat = 13

    var body: some View {
        let attributed = Self.attributed(text)
        SelectableLinkTextView(
            attributedString: attributed,
            fontSize: fontSize,
            textColor: NSColor(baseColor)
        )
    }

    static func attributed(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var attributed = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        for range in AgentProfileTokenHighlight.ranges(in: text) {
            let snippet = String(text[range])
            if let match = attributed.range(of: snippet) {
                attributed[match].foregroundColor = AgentProfileTokenColor.darkGreen
            }
        }
        return attributed
    }
}
