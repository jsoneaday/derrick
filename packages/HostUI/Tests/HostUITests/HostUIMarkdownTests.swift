import HostUI
import Testing

@MainActor
@Suite struct HostUIMarkdownTests {
    @Test func rendersInlineBold() {
        let attributed = HostUIMarkdown.attributed("Assuming **New York City**: it's currently **fair**")
        #expect(String(attributed.characters).contains("New York City"))
        #expect(String(attributed.characters).contains("fair"))
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    @Test func keepsPlainText() {
        #expect(String(HostUIMarkdown.attributed("hello").characters) == "hello")
    }

    @Test func parsesMarkdownLinks() {
        let attributed = HostUIMarkdown.attributed(
            "See [AccuWeather](https://www.accuweather.com) for details."
        )
        #expect(attributed.containsLinks)
        #expect(String(attributed.characters).contains("AccuWeather"))
    }
}

@MainActor
@Suite struct HostUIControlKitTests {
    @Test func buttonAndFieldAreTheCatalogControls() {
        let _ = HostUIButton("Send", systemImage: "paperplane.fill") {}
        let _ = HostUIButton("Cancel", chrome: .secondary) {}
        var draft = ""
        let _ = HostUITextField("Message", text: .init(get: { draft }, set: { draft = $0 }), axis: .vertical)
        let _ = HostUITextField("Reply", text: .init(get: { draft }, set: { draft = $0 }), chrome: .plain)
        let _ = HostUIMarkdownText("**hi**", fontSize: 13)
    }
}
