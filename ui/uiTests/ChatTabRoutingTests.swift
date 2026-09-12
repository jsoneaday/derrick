import Testing
@testable import ui

@Suite struct ChatTabRoutingTests {
    @Test func pluginRootAndThreadTabIDsAreStableAndDistinct() {
        let plugin = ChatTab.pluginRootID("slack-bot")
        let thread = ChatTab.pluginThreadID(pluginID: "slack-bot", threadID: "C123")
        #expect(plugin == "plugin:slack-bot")
        #expect(thread == "plugin:slack-bot:thread:C123")
        #expect(plugin != thread)
    }

    @MainActor
    @Test func openOrFocusPluginReusesTheSameTab() {
        let store = ChatSessionStore()
        let first = store.openOrFocusPlugin(pluginID: "weather-tool", surface: .conversation)
        let second = store.openOrFocusPlugin(pluginID: "weather-tool", surface: .conversation)
        #expect(first == second)
        #expect(store.tabs.filter { $0.pluginID == "weather-tool" }.count == 1)
        #expect(store.selectedSessionID == first)
        #expect(store.selectedTab?.surface == .conversation)
    }

    @MainActor
    @Test func openOrFocusThreadReusesTheSameTabAndKeepsPluginRootSeparate() {
        let store = ChatSessionStore()
        let root = store.openOrFocusPlugin(pluginID: "slack-bot", surface: .thread)
        let thread = store.openOrFocusThread(
            pluginID: "slack-bot",
            threadID: "thread-1",
            title: "#general"
        )
        let again = store.openOrFocusThread(
            pluginID: "slack-bot",
            threadID: "thread-1",
            title: "#general"
        )
        #expect(root != thread)
        #expect(thread == again)
        #expect(store.tabs.count == 2)
        #expect(store.selectedSessionID == thread)
        #expect(store.selectedTab?.surface == .thread)
        #expect(store.selectedTab?.title == "#general")
    }

    @Test func settingsSidebarIncludesPlugins() {
        #expect(LLMModelSettingsSidebarItem.plugins.title == "Plugins")
        #expect(LLMModelSettingsSidebarItem.allCases.contains(.plugins))
    }

    @Test func hostBindsSurfaceWithoutAskingTheHuman() {
        #expect(ChatTabSurfacePolicy.bind(isMessagingConnector: true) == .decided(.thread))
        #expect(ChatTabSurfacePolicy.bind(isMessagingConnector: false) == .decided(.conversation))
        #expect(ChatTabSurfacePolicy.bind(isMessagingConnector: true) != .needsHumanChoice)
        #expect(ChatTabSurfacePolicy.bind(isMessagingConnector: false) != .needsHumanChoice)
    }

    @Test func returnClassBindsGeneratedViewFileAndImageSurfaces() {
        #expect(
            ChatTabSurfacePolicy.bind(spec: PluginSpecDraft(returnClass: .list))
                == .decided(.generatedView)
        )
        #expect(
            ChatTabSurfacePolicy.bind(spec: PluginSpecDraft(returnClass: .file))
                == .decided(.file)
        )
        #expect(
            ChatTabSurfacePolicy.bind(spec: PluginSpecDraft(returnClass: .image))
                == .decided(.image)
        )
        #expect(
            ChatTabSurfacePolicy.bind(present: .generatedView) == .decided(.generatedView)
        )
    }

    @Test func creatorTabIDIsStable() {
        #expect(PluginSpecProcession.creatorTabID == "plugin-creator")
        #expect(ChatTabSurface(PluginPresent.file) == .file)
    }
}
