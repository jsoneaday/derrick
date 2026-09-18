import AppKit
import SwiftUI

/// Selectable markdown/attributed text that shows the pointing-hand cursor over links.
/// SwiftUI `Text` + `.textSelection(.enabled)` forces the I-beam and overrides `.pointerStyle(.link)`.
struct SelectableLinkTextView: NSViewRepresentable {
    let attributedString: AttributedString
    var fontSize: CGFloat = 13
    var textColor: NSColor = .labelColor
    /// Cap ideal (uncompressed) width so `ViewThatFits` / trailing bubbles stay reasonable.
    var maxIdealWidth: CGFloat = 420

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MeasuringLinkTextView {
        let textView = MeasuringLinkTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: 0,
            .cursor: NSCursor.pointingHand,
        ]
        apply(to: textView)
        return textView
    }

    func updateNSView(_ textView: MeasuringLinkTextView, context: Context) {
        textView.delegate = context.coordinator
        apply(to: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MeasuringLinkTextView,
        context: Context
    ) -> CGSize? {
        apply(to: nsView)
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 1 {
            width = proposed
        } else {
            width = min(max(nsView.idealWidth(), 1), maxIdealWidth)
        }
        let height = nsView.height(forWidth: width)
        return CGSize(width: width, height: height)
    }

    private func apply(to textView: MeasuringLinkTextView) {
        let nsFont = NSFont.systemFont(ofSize: fontSize)
        var styled = attributedString
        styled.font = Font(nsFont)
        styled.foregroundColor = Color(nsColor: textColor)

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

/// NSTextView that measures height for a given width without fighting SwiftUI layout.
final class MeasuringLinkTextView: NSTextView {
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

extension AttributedString {
    var containsLinks: Bool {
        runs.contains { $0.link != nil }
    }
}
