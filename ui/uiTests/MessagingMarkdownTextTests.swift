import Foundation
import Testing
@testable import ui

@MainActor
@Suite struct MessagingMarkdownTextTests {
    @Test func rendersInlineBold() {
        let attributed = MessagingMarkdownText.attributed("Assuming **New York City**: it's currently **fair**")
        #expect(String(attributed.characters).contains("New York City"))
        #expect(String(attributed.characters).contains("fair"))
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    @Test func keepsPlainText() {
        let attributed = MessagingMarkdownText.attributed("hello")
        #expect(String(attributed.characters) == "hello")
    }

    @Test func parsesMarkdownLinks() {
        let attributed = MessagingMarkdownText.attributed(
            "See [AccuWeather](https://www.accuweather.com) for details."
        )
        #expect(attributed.containsLinks)
        #expect(String(attributed.characters).contains("AccuWeather"))
    }
}
