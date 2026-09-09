import Structure
import SwiftUI

enum AgentProfileTokenColor {
    /// Darker than system green so `$profile` tokens stay readable on light bubbles.
    static let darkGreen = Color(red: 0.0, green: 0.42, blue: 0.18)
}

struct AgentProfileHighlightedText: View {
    let text: String
    var font: Font = .body
    var baseColor: Color = .primary

    var body: some View {
        Text(highlighted)
            .font(font)
            .foregroundStyle(baseColor)
    }

    private var highlighted: AttributedString {
        var attributed = AttributedString(text)
        for nsRange in AgentProfileTokenHighlight.nsRanges(in: text) {
            guard let range = Range(nsRange, in: attributed) else { continue }
            attributed[range].foregroundColor = AgentProfileTokenColor.darkGreen
        }
        return attributed
    }
}
