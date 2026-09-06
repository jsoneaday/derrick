import AppKit
import Testing
@testable import ui

@Suite struct LLMModelSettingsPanelTests {
    @MainActor
    @Test func windowChromeKeepsStandardTrafficLights() {
        let host = NSViewController()
        let window = LLMModelSettingsWindowChrome.makeWindow(contentViewController: host)
        defer { window.close() }

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.toolbarStyle == .unified)
        #expect(window.toolbar != nil)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)
    }

    @Test func settingsLayoutKeepsMatchingSidebarInsets() {
        #expect(SettingsLayout.sidebarRowHorizontal == 10)
        #expect(SettingsLayout.sidebarListPadding == 12)
        #expect(SettingsLayout.fieldIndent == 16)
        #expect(SettingsLayout.sectionSpacing == 24)
    }

    @Test func pluginCreationElapsedWaitHidesTheFirstFewSeconds() {
        #expect(PluginCreationElapsedWait.label(elapsedSeconds: 3) == nil)
        #expect(PluginCreationElapsedWait.label(elapsedSeconds: 8) == "Still working · 8 seconds")
        #expect(PluginCreationElapsedWait.label(elapsedSeconds: 60) == "Still working · 1 min")
        #expect(PluginCreationElapsedWait.label(elapsedSeconds: 125) == "Still working · 2 min 5 sec")
    }
}
