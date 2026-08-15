import Foundation
import Testing
@testable import Plugin

@Suite struct PluginInvokePresentationTests {
    @Test func prefixInvokeShowsStdoutNotToolDump() {
        let raw = """
        {"status":"completed","failureStage":"none","stdout":"1. Markets rise\\n2. Storms ease","stderr":"","exitCode":0,"timedOut":false}
        """
        let text = PluginInvokePresentation.userFacingText(fromScriptResult: raw)
        #expect(text.contains("Markets rise"))
        #expect(!text.contains("tool:"))
        #expect(!text.contains("exitCode"))
        #expect(!text.contains("timedOut"))
    }

    @Test func emptyNumberedListIsVacuous() {
        let raw = """
        {"status":"completed","stdout":"1.\\n2.\\n3.\\n4.\\n5.\\n6.\\n7.\\n8.\\n9.\\n10.","exitCode":0}
        """
        let text = PluginInvokePresentation.userFacingText(fromScriptResult: raw)
        #expect(text == "no display content")
        #expect(PluginInvokePresentation.isVacuous("1.\n2.\n3."))
        #expect(!PluginInvokePresentation.isVacuous("1. Markets rise\n2. Storms ease"))
        let report = PluginInvokePresentation.testReport(
            pluginID: "daily-news-summary",
            scriptResult: raw
        )
        #expect(report.heading.hasPrefix("Testing new plugin daily-news-summary"))
        #expect(report.kind == .programmatic)
        let encoded = PluginInvokePresentation.encodeTestReport(report)
        #expect(PluginInvokePresentation.decodeTestReport(encoded)?.body == report.body)
    }

    @Test func failureUsesFindings() {
        let raw = """
        {"status":"failed","failureStage":"execution","validationFindings":["handle() returned no terminal verb."],"stdout":"","exitCode":-1}
        """
        let text = PluginInvokePresentation.userFacingText(fromScriptResult: raw)
        #expect(text.contains("no terminal verb"))
    }
}
