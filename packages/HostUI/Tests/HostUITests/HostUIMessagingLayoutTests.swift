import HostUI
import Testing

@MainActor
@Suite struct HostUIMessagingLayoutTests {
    @Test func shortCopyHugsWellBelowTheWidthCap() {
        let hi = HostUIMessagingLayout.huggingWidth(for: "hi")
        let phrase = HostUIMessagingLayout.huggingWidth(for: "hi from derrick")
        #expect(hi < 60)
        #expect(phrase < 200)
        #expect(hi < HostUIMessagingLayout.maxBubbleWidth)
        #expect(phrase < HostUIMessagingLayout.maxBubbleWidth)
    }

    @Test func longCopyUsesAFractionOfTheContainer() {
        let long = String(repeating: "word ", count: 80)
        let narrow = HostUIMessagingLayout.huggingWidth(for: long, containerWidth: 280)
        let expected = HostUIMessagingLayout.cappedBubbleWidth(ideal: 10_000, containerWidth: 280)
        #expect(narrow == expected)
        #expect(abs(narrow - 280 * HostUIMessagingLayout.maxBubbleFraction) < 0.51)
        #expect(HostUIMessagingLayout.huggingWidth(for: long) == HostUIMessagingLayout.maxBubbleWidth)
    }

    @Test func replyPreviewIsOneLineAndCapped() {
        let preview = HostUIMessagingLayout.collapsedReplyPreview(
            "First paragraph.\n\nSecond paragraph that must not become a channel message."
        )
        #expect(!preview.contains("\n"))
        #expect(preview.contains("First paragraph."))
    }
}
