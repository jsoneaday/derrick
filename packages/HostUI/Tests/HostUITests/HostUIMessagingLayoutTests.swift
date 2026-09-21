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

    @Test func sidebarAndChromeScaleWithTheContainerNotPointLocks() {
        let narrow = HostUIMessagingLayout.sidebarWidth(forContainer: 520)
        let wide = HostUIMessagingLayout.sidebarWidth(forContainer: 1440)
        #expect(narrow < wide)
        #expect(abs(narrow - 520 * HostUIMessagingLayout.sidebarFraction) < 0.51)
        #expect(abs(wide - 1440 * HostUIMessagingLayout.sidebarFraction) < 0.51)
        #expect(narrow != 300)
        #expect(wide != 440)

        let narrowGutter = HostUIMessagingLayout.oppositeGutter(forPane: 280)
        let wideGutter = HostUIMessagingLayout.oppositeGutter(forPane: 900)
        #expect(narrowGutter < wideGutter)
        #expect(HostUIMessagingLayout.listPaddingX(forPane: 280) <= HostUIMessagingLayout.listPaddingX(forPane: 900))
        #expect(HostUIMessagingLayout.composerPaddingX(forPane: 520) <= HostUIMessagingLayout.composerPaddingX(forPane: 1100))
    }

    @Test func replyPreviewIsOneLineAndCapped() {
        let preview = HostUIMessagingLayout.collapsedReplyPreview(
            "First paragraph.\n\nSecond paragraph that must not become a channel message."
        )
        #expect(!preview.contains("\n"))
        #expect(preview.contains("First paragraph."))
    }
}
