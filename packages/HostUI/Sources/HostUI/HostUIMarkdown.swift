import AppKit
import Structure
import SwiftUI

/// Shared markdown + `$profile` token coloring for HostUI message bodies.
public enum HostUIMarkdown {
    /// Dark green for `$handle` and `[Derrick:handle]`. Darker than system green on white bubbles.
    public static let profileTokenColor = Color(red: 0.0, green: 0.42, blue: 0.18)

    public static func attributed(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var attributed = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        colorProfileTokens(&attributed)
        return attributed
    }

    /// Paints `$handle` and `[Derrick:handle]` on already-rendered text. Later copies of the same token are included.
    public static func colorProfileTokens(_ attributed: inout AttributedString) {
        let source = String(attributed.characters)
        var search = attributed.startIndex
        for range in AgentProfileTokenHighlight.ranges(in: source) {
            let snippet = String(source[range])
            guard !snippet.isEmpty, let match = attributed[search...].range(of: snippet) else { continue }
            attributed[match].foregroundColor = profileTokenColor
            search = match.upperBound
        }
    }
}

/// Plain text with `$handle` and `[Derrick:handle]` in `HostUIMarkdown.profileTokenColor`.
public struct HostUIProfileTokenText: View {
    private let text: String
    private let base: Color

    public init(_ text: String, base: Color) {
        self.text = text
        self.base = base
    }

    public var body: some View {
        Text(Self.attributed(text, base: base))
    }

    public static func attributed(_ text: String, base: Color) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = base
        HostUIMarkdown.colorProfileTokens(&attributed)
        return attributed
    }
}

extension AttributedString {
    public var containsLinks: Bool {
        runs.contains { $0.link != nil }
    }
}

/// How rendered markdown measures itself. Bubbles hug short copy. Documents fill the proposed width.
public enum HostUIMarkdownSizing: Sendable {
    case bubble
    case document(maxIdealWidth: CGFloat)
}

public struct HostUIMarkdownText: View {
    private let text: String
    private let fontSize: CGFloat
    private let sizing: HostUIMarkdownSizing

    public init(_ text: String, font: Font = .system(size: 13), maxIdealWidth: CGFloat = HostUIMessagingLayout.maxBubbleWidth) {
        self.text = text
        // HostUI bubbles size via AppKit measurement; keep a numeric size.
        self.fontSize = 13
        self.sizing = .bubble
        _ = font
        _ = maxIdealWidth
    }

    public init(_ text: String, fontSize: CGFloat, maxIdealWidth: CGFloat = HostUIMessagingLayout.maxBubbleWidth) {
        self.text = text
        self.fontSize = fontSize
        self.sizing = .bubble
        _ = maxIdealWidth
    }

    public init(_ text: String, fontSize: CGFloat, sizing: HostUIMarkdownSizing) {
        self.text = text
        self.fontSize = fontSize
        self.sizing = sizing
    }

    public var body: some View {
        HostUIMeasuringMarkdownText(
            attributedString: HostUIMarkdown.attributed(text),
            fontSize: fontSize,
            sizing: sizing
        )
        .tint(Color(red: 0.176, green: 0.286, blue: 0.576))
    }
}

/// Selectable markdown that reports ideal width so chat bubbles hug short text.
private struct HostUIMeasuringMarkdownText: NSViewRepresentable {
    let attributedString: AttributedString
    var fontSize: CGFloat = 13
    var sizing: HostUIMarkdownSizing = .bubble

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> HostUIMeasuringTextView {
        let textView = HostUIMeasuringTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: 0,
            .cursor: NSCursor.pointingHand,
        ]
        apply(to: textView)
        return textView
    }

    func updateNSView(_ textView: HostUIMeasuringTextView, context: Context) {
        textView.delegate = context.coordinator
        apply(to: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: HostUIMeasuringTextView,
        context: Context
    ) -> CGSize? {
        apply(to: nsView)
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
        let width = measuredWidth(ideal: nsView.idealWidth(), proposed: proposed)
        let height = nsView.height(forWidth: width)
        return CGSize(width: width, height: height)
    }

    private func apply(to textView: HostUIMeasuringTextView) {
        let nsFont = NSFont.systemFont(ofSize: fontSize)
        var styled = attributedString
        styled.font = Font(nsFont)
        styled.foregroundColor = Color(nsColor: .labelColor)
        HostUIMarkdown.colorProfileTokens(&styled)

        let next = NSMutableAttributedString(attributedString: NSAttributedString(styled))
        next.enumerateAttribute(.link, in: NSRange(location: 0, length: next.length)) { value, range, _ in
            guard value != nil else { return }
            next.addAttribute(.cursor, value: NSCursor.pointingHand, range: range)
            next.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }

        if textView.textStorage?.string != next.string {
            textView.textStorage?.setAttributedString(next)
        } else if let storage = textView.textStorage, !storage.isEqual(to: next) {
            storage.setAttributedString(next)
        }
    }

    private func measuredWidth(ideal: CGFloat, proposed: CGFloat?) -> CGFloat {
        switch sizing {
        case .bubble:
            return HostUIMessagingLayout.cappedBubbleWidth(ideal: ideal, containerWidth: proposed)
        case .document(let maxIdealWidth):
            if let proposed {
                return proposed
            }
            return min(max(ideal, 1), maxIdealWidth)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let value = link as? URL {
                url = value
            } else if let value = link as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            guard let url else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

final class HostUIMeasuringTextView: NSTextView {
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layoutManager else {
            return ceil(font?.boundingRectForFont.height ?? 16)
        }
        let clamped = max(width, 1)
        container.containerSize = NSSize(width: clamped, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return max(ceil(used.height), ceil(font?.boundingRectForFont.height ?? 16))
    }

    func idealWidth() -> CGFloat {
        guard let container = textContainer, let layoutManager else { return 1 }
        container.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return max(ceil(used.width), 1)
    }
}
