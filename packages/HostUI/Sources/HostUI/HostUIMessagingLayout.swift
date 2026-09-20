import AppKit
import SwiftUI

/// Single messaging chrome contract. Direction may place a row left or right;
/// it must not pick a second bubble, fill, stroke, or width policy.
public enum HostUIMessagingLayout {
    public static let navy = Color(red: 0.176, green: 0.286, blue: 0.576)
    public static let bubbleFill = Color.white
    public static let bubbleStrokeOpacity = 0.14
    public static let bubbleCornerRadius: CGFloat = 14
    public static let bubblePaddingX: CGFloat = 14
    public static let bubblePaddingY: CGFloat = 10
    /// Long copy uses this share of the row/pane, then hugs if the text is shorter.
    public static let maxBubbleFraction: CGFloat = 0.72
    /// Ceiling so a 5K channel does not become one full-width paragraph.
    public static let maxBubbleWidth: CGFloat = 520
    /// Gutter opposite the bubble. Keep small so a reply pane can still wrap.
    public static let oppositeGutter: CGFloat = 24
    public static let listPaddingX: CGFloat = 12
    public static let replyPreviewCharacterCap = 96

    public static func collapsedReplyPreview(_ raw: String) -> String {
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= replyPreviewCharacterCap { return oneLine }
        let idx = oneLine.index(oneLine.startIndex, offsetBy: replyPreviewCharacterCap)
        return String(oneLine[..<idx]) + "…"
    }

    /// Cap for bubble body width: min(ideal, fraction of container, absolute ceiling).
    public static func cappedBubbleWidth(ideal: CGFloat, containerWidth: CGFloat?) -> CGFloat {
        let fractionCap: CGFloat
        if let containerWidth, containerWidth.isFinite, containerWidth > 1 {
            fractionCap = containerWidth * maxBubbleFraction
        } else {
            fractionCap = maxBubbleWidth
        }
        return min(max(ideal, 1), min(maxBubbleWidth, fractionCap))
    }

    /// Ideal body width used by bubbles. Short copy hugs; long copy follows `cappedBubbleWidth`.
    @MainActor
    public static func huggingWidth(
        for text: String,
        fontSize: CGFloat = 13,
        containerWidth: CGFloat? = nil
    ) -> CGFloat {
        let view = HostUIMeasuringTextView(usingTextLayoutManager: false)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        let nsFont = NSFont.systemFont(ofSize: fontSize)
        var styled = HostUIMarkdown.attributed(text)
        styled.font = Font(nsFont)
        view.textStorage?.setAttributedString(NSAttributedString(styled))
        return cappedBubbleWidth(ideal: view.idealWidth(), containerWidth: containerWidth)
    }
}

/// The one message pill. Inbound and outbound both use this; placement lives in `HostUIMessage`.
struct HostUIMessageBubble: View {
    let bodyMarkdown: String

    var body: some View {
        HostUIMarkdownText(bodyMarkdown, fontSize: 13)
        .padding(.horizontal, HostUIMessagingLayout.bubblePaddingX)
        .padding(.vertical, HostUIMessagingLayout.bubblePaddingY)
        .background(
            RoundedRectangle(cornerRadius: HostUIMessagingLayout.bubbleCornerRadius, style: .continuous)
                .fill(HostUIMessagingLayout.bubbleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HostUIMessagingLayout.bubbleCornerRadius, style: .continuous)
                .strokeBorder(
                    HostUIMessagingLayout.navy.opacity(HostUIMessagingLayout.bubbleStrokeOpacity),
                    lineWidth: 1
                )
        )
        // Wrap to the proposed pane width; do not ignore a narrower sidebar.
        .fixedSize(horizontal: false, vertical: true)
    }
}
