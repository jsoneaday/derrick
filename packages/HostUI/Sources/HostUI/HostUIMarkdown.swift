import AppKit
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

extension AttributedString {
    public var containsLinks: Bool {
        runs.contains { $0.link != nil }
    }
}

public struct HostUIMarkdownText: View {
    private let text: String
    private let fontSize: CGFloat
    private let maxIdealWidth: CGFloat

    public init(_ text: String, font: Font = .system(size: 13), maxIdealWidth: CGFloat = HostUIMessagingLayout.maxBubbleWidth) {
        self.text = text
        // HostUI bubbles size via AppKit measurement; keep a numeric size.
        self.fontSize = 13
        self.maxIdealWidth = maxIdealWidth
        _ = font
    }

    public init(_ text: String, fontSize: CGFloat, maxIdealWidth: CGFloat = HostUIMessagingLayout.maxBubbleWidth) {
        self.text = text
        self.fontSize = fontSize
        self.maxIdealWidth = maxIdealWidth
    }

    public var body: some View {
        HostUIMeasuringMarkdownText(
            attributedString: HostUIMarkdown.attributed(text),
            fontSize: fontSize,
            maxIdealWidth: maxIdealWidth
        )
        .tint(Color(red: 0.176, green: 0.286, blue: 0.576))
    }
}

/// Selectable markdown that reports ideal width so chat bubbles hug short text.
private struct HostUIMeasuringMarkdownText: NSViewRepresentable {
    let attributedString: AttributedString
    var fontSize: CGFloat = 13
    var maxIdealWidth: CGFloat = 420

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
        let width = HostUIMessagingLayout.cappedBubbleWidth(
            ideal: nsView.idealWidth(),
            containerWidth: proposed
        )
        let height = nsView.height(forWidth: width)
        return CGSize(width: width, height: height)
    }

    private func apply(to textView: HostUIMeasuringTextView) {
        let nsFont = NSFont.systemFont(ofSize: fontSize)
        var styled = attributedString
        styled.font = Font(nsFont)
        styled.foregroundColor = Color(nsColor: .labelColor)

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
