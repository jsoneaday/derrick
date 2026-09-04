import AppKit
import SwiftUI

struct DebugLogTextView: NSViewRepresentable {
    let text: String
    var autoScrollToEnd = true

    private func makeAttributedString() -> NSAttributedString {
        let lines = text.components(separatedBy: .newlines)
        var combined = AttributedString()

        for (index, line) in lines.enumerated() {
            var lineAttr = (try? AttributedString(markdown: line)) ?? AttributedString(line)
            if index < lines.count - 1 {
                lineAttr.append(AttributedString("\n"))
            }
            combined.append(lineAttr)
        }

        combined.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        combined.foregroundColor = Color(NSColor.labelColor)
        return NSAttributedString(combined)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let nsAttributed = makeAttributedString()
        textView.textStorage?.setAttributedString(nsAttributed)
        if autoScrollToEnd {
            textView.scrollToEndOfDocument(nil)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else {
            return
        }

        let nsAttributed = makeAttributedString()
        if textView.attributedString() != nsAttributed {
            textView.textStorage?.setAttributedString(nsAttributed)
            if autoScrollToEnd {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }
}
