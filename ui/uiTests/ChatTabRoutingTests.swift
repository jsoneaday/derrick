import Testing
import Structure
import CoreGraphics
@testable import ui

@Suite struct ChatTabRoutingTests {
    @Test func pluginRootAndThreadTabIDsAreStableAndDistinct() {
        let plugin = ChatTab.pluginRootID("slack-bot")
        let thread = ChatTab.pluginThreadID(pluginID: "slack-bot", threadID: "C123")
        #expect(plugin == "plugin:slack-bot")
        #expect(thread == "plugin:slack-bot:thread:C123")
        #expect(plugin != thread)
        let identity = ChatTab.pluginTabIdentity(thread)
        #expect(identity?.pluginID == "slack-bot")
        #expect(identity?.threadID == "C123")
        #expect(ChatTab.pluginTabIdentity(plugin)?.threadID == nil)
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
        #expect(PluginSpecProcession.isCreatorTabID("plugin-creator"))
        #expect(PluginSpecProcession.isCreatorTabID("plugin-creator-abc"))
        #expect(PluginSpecProcession.isCreatorTabID("chat") == false)
        #expect(ChatTabSurface(PluginPresent.file) == .file)
    }

    @Test func newPluginSitsBelowNewChatInTheSidebar() {
        #expect(SidebarPrimaryActions.newChat.title == "New chat")
        #expect(SidebarPrimaryActions.newPlugin.title == "New plugin")
        #expect(SidebarPrimaryActions.newPlugin.id == "new-plugin")
    }

    @Test func pluginCreatorIntroExplainsWhatAPluginIs() {
        #expect(PluginCreatorIntroCopy.body.contains("extension to derrick"))
        #expect(PluginCreatorIntroCopy.body.contains("additional capability to derrick"))
        #expect(PluginCreatorIntroCopy.body.contains("Once created a plugin can be called by typing '/<plugin name>'"))
    }

    @Test func pluginCreatorTabIsNotAnEmptyChat() {
        let empty = ChatTab(id: PluginSpecProcession.creatorTabID, title: "Create plugin")
        #expect(empty.turns.isEmpty)
        #expect(empty.isPluginCreator == false)

        let seeded = ChatTab.pluginCreator(existing: empty)
        #expect(seeded.isPluginCreator)
        #expect(seeded.turns.isEmpty == false)
        #expect(seeded.turns.first?.prompt == "Create plugin")
        #expect(seeded.turns.first?.response == PluginSpecProcession.openingQuestion)

        let fresh = ChatTab.pluginCreator()
        #expect(PluginSpecProcession.isCreatorTabID(fresh.id))
        #expect(fresh.turns.isEmpty == false)
        #expect(fresh.isPluginCreator)
        #expect(fresh.title == PluginSpecProcession.creatorTabTitlePrefix)
    }

    @MainActor
    @Test func newPluginOpensAFreshCreatorTabEachTime() {
        let store = ChatSessionStore()
        let first = store.openOrFocusPluginCreator()
        let second = store.openOrFocusPluginCreator()
        #expect(first != second)
        #expect(PluginSpecProcession.isCreatorTabID(first))
        #expect(PluginSpecProcession.isCreatorTabID(second))
        #expect(store.tabs.filter(\.isPluginCreator).count == 2)
        #expect(store.selectedSessionID == second)
        #expect(store.selectedTab?.title == PluginSpecProcession.creatorTabTitlePrefix)
    }

    @MainActor
    @Test func recentsChannelTabOpensThePluginInboxInstead() {
        let store = ChatSessionStore()
        let channelID = ChatTab.pluginThreadID(pluginID: "slack-connector-1", threadID: "C123")
        store.selectSession(id: channelID)
        #expect(store.tabs.contains { $0.id == channelID } == false)
        #expect(store.selectedSessionID == ChatTab.pluginRootID("slack-connector-1"))
        #expect(store.selectedTab?.threadID == nil)
        #expect(store.selectedTab?.pluginID == "slack-connector-1")
    }

    @Test func pluginCreatorKeepsDescriptionTitleWhenReseeded() {
        var tab = ChatTab.pluginCreator()
        tab.title = PluginSpecProcession.creatorTabTitle(from: "connect to slack and send receive messages")
        let reseeded = ChatTab.pluginCreator(existing: tab)
        #expect(reseeded.title == tab.title)
        #expect(reseeded.title.hasPrefix("Create plugin - "))
    }

    @Test func pluginCreatorTabTitleUpdatesAfterClaimedOutcome() {
        var tab = ChatTab.pluginCreator()
        #expect(tab.title == PluginSpecProcession.creatorTabTitlePrefix)
        _ = tab.applyCreatorUtterance("connect to slack and send receive messages")
        #expect(tab.title == PluginSpecProcession.creatorTabTitle(
            from: "connect to slack and send receive messages"
        ))
        #expect(tab.title.hasPrefix("Create plugin - "))
        #expect(tab.title.contains("slack"))
    }

    @Test func pluginCreatorAccessWaitsForDocsThenAsksFromTheSummary() {
        var tab = ChatTab.pluginCreator()
        _ = tab.applyCreatorUtterance("connect to slack and send receive messages")
        #expect(tab.specSession?.ask == .slot(.access))
        #expect(tab.turns.last?.response == PluginAccessAskPolicy.reviewingQuestion)

        let discovery = ConnectorAuthDiscovery(
            authScheme: .botToken,
            secrets: [PluginSecretField.slackBotToken],
            setupHint: "Slack apps authenticate with a bot token that can read and send messages.",
            crawlSummary: "Bot user OAuth tokens start with xoxb-."
        )
        tab.applyAccessDiscovery(
            discovery,
            documentationURL: "https://docs.example.com/auth/tokens"
        )
        let reply = tab.turns.last?.response ?? ""
        #expect(reply.contains("bot token"))
        #expect(reply.contains("https://docs.example.com/auth/tokens"))
        #expect(reply.contains(PluginAccessAskPolicy.reviewingQuestion) == false)
    }

    @Test func pluginCreatorAsksForDocsURLWhenReviewFindsNothing() {
        var tab = ChatTab.pluginCreator()
        _ = tab.applyCreatorUtterance("Summaries of tech news")
        _ = tab.applyCreatorUtterance("Google News")
        #expect(tab.specSession?.ask == .slot(.access))
        #expect(tab.turns.last?.response == PluginAccessAskPolicy.reviewingQuestion)

        tab.applyDocsReviewFailed()
        #expect(tab.specSession?.ask == .docsURL)
        #expect(tab.turns.last?.response == PluginAccessAskPolicy.docsURLFindQuestion)
        #expect(tab.turns.last?.status == .complete)
        #expect(tab.isStreaming == false)

        tab.applyDocsReviewFailed(failure: .webToolsNotReady)
        #expect(tab.turns.last?.response == PluginAccessAskPolicy.webToolsNotReadyQuestion)

        _ = tab.applyCreatorUtterance("can you search for it")
        #expect(tab.specSession?.ask == .slot(.access))
        #expect(tab.turns.last?.response == PluginAccessAskPolicy.reviewingQuestion)
        #expect(tab.turns.last?.status == .thinking)
    }

    @Test func pluginCreatorDocsReviewShowsProgressThenNamesASearchHitOnFailure() {
        var tab = ChatTab.pluginCreator()
        _ = tab.applyCreatorUtterance("connect to slack and send receive messages")
        #expect(tab.turns.last?.status == .thinking)
        #expect(tab.turns.last?.response == PluginAccessAskPolicy.reviewingQuestion)

        tab.beginAccessDocsReview()
        #expect(tab.isStreaming)
        #expect(tab.turns.last?.status == .thinking)

        tab.applyDocsReviewFailed(
            triedURL: "https://api.slack.com/authentication/basics",
            fromHuman: false
        )
        let reply = tab.turns.last?.response ?? ""
        #expect(reply.contains("https://api.slack.com/authentication/basics"))
        #expect(reply.contains("looked at"))
        #expect(reply.contains("Paste a different page") == false)
        #expect(tab.turns.last?.status == .complete)
        #expect(tab.isStreaming == false)
    }

    @Test func chatSidebarWidthShrinksOnNarrowWindows() {
        #expect(ChatSidebarWidth.value(windowWidth: 1400) == ChatSidebarWidth.expanded)
        #expect(ChatSidebarWidth.value(windowWidth: 960) == ChatSidebarWidth.compact)
        let mid = ChatSidebarWidth.value(windowWidth: 1120)
        #expect(mid > ChatSidebarWidth.compact)
        #expect(mid < ChatSidebarWidth.expanded)
    }
}
