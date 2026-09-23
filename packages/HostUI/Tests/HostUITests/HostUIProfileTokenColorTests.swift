import HostUI
import Testing

@MainActor
@Suite struct HostUIProfileTokenColorTests {
    @Test func dollarHandleAndSenderPrefixShareMediumGreen() {
        let text = "$orchestrator then [Derrick:$developer] done"
        let attributed = HostUIMarkdown.attributed(text)
        let snippets = attributed.runs.compactMap { run -> String? in
            guard attributed[run.range].foregroundColor == HostUIMarkdown.profileTokenColor else {
                return nil
            }
            return String(attributed[run.range].characters)
        }
        #expect(snippets == ["$orchestrator", "[Derrick:$developer]"])
    }

    @Test func plainPreviewKeepsTheSameGreenOnTheSenderPrefix() {
        let attributed = HostUIProfileTokenText.attributed(
            "[Derrick:$orchestrator] Searching the web…",
            base: .secondary
        )
        let green = attributed.runs.compactMap { run -> String? in
            guard attributed[run.range].foregroundColor == HostUIMarkdown.profileTokenColor else {
                return nil
            }
            return String(attributed[run.range].characters)
        }
        #expect(green == ["[Derrick:$orchestrator]"])
    }
}
