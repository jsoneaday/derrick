import Structure
import SwiftUI

/// Shared markdown + `$profile` token coloring for HostUI message bodies.
public enum HostUIMarkdown {
    public static func attributed(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var attributed = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        for range in AgentProfileTokenHighlight.ranges(in: text) {
            let snippet = String(text[range])
            if let match = attributed.range(of: snippet) {
                attributed[match].foregroundColor = Color(red: 0.0, green: 0.42, blue: 0.18)
            }
        }
        return attributed
    }
}

public struct HostUIMarkdownText: View {
    private let text: String
    private let font: Font

    public init(_ text: String, font: Font = .system(size: 13)) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Text(HostUIMarkdown.attributed(text))
            .font(font)
            .textSelection(.enabled)
            .tint(Color(red: 0.176, green: 0.286, blue: 0.576))
    }
}
