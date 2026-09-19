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
        #expect(SidebarPrimaryActions.plugins.title == "Plugins")
        #expect(SidebarPrimaryActions.pluginsCreate.title == "Create")
        #expect(SidebarPrimaryActions.pluginsList.title == "List")
        #expect(SidebarPrimaryActions.plugins.id == "plugins")
        #expect(SidebarPrimaryActions.pluginsCreate.id == "plugins-create")
        #expect(SidebarPrimaryActions.pluginsList.id == "plugins-list")
    }

    @Test func chatTabBarIncludesOngoingCreatesOnly() {
        #expect(ChatTabBarView.TabFilter.chats != .pluginsCreate)
        let fresh = ChatTab.pluginCreator()
        #expect(fresh.isOngoingPluginCreator == false)
        var ongoing = ChatTab.pluginCreator()
        ongoing.turns.append(
            ChatTurn(prompt: "Slack bot", response: "Next question", status: .complete)
        )
        #expect(ongoing.isOngoingPluginCreator)
    }

    @Test func pluginsCreateAndListAreSeparateFromChat() {
        #expect(AppWorkspace.pluginsCreate != .chats)
        #expect(AppWorkspace.pluginsList != .chats)
        #expect(AppWorkspace.pluginsCreate != .pluginsList)
        #expect(AppWorkspace.pluginsCreate.isPluginsSection)
        #expect(AppWorkspace.pluginsList.isPluginsSection)
        #expect(!AppWorkspace.chats.isPluginsSection)
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
        #expect(fresh.title == PluginSpecProcession.pluginsTabTitle)
        #expect(seeded.title == PluginSpecProcession.pluginsTabTitle)
    }

    @MainActor
    @Test func createPluginReusesUnusedCreatorTabAndDoesNotPersistYet() {
        let store = ChatSessionStore()
        let first = store.openOrFocusPluginCreator()
        let second = store.openOrFocusPluginCreator()
        #expect(first == second)
        #expect(PluginSpecProcession.isCreatorTabID(first))
        #expect(store.tabs.filter(\.isPluginCreator).count == 1)
        #expect(store.selectedSessionID == first)
        #expect(store.selectedTab?.isUnusedPluginCreator == true)
        #expect(store.selectedTab?.title == PluginSpecProcession.pluginsTabTitle)
    }

    @MainActor
    @Test func unusedCreatorIsHiddenFromChatTabFilter() {
        let unused = ChatTab.pluginCreator()
        #expect(unused.isUnusedPluginCreator)
        var started = ChatTab.pluginCreator()
        started.turns.append(
            ChatTurn(prompt: "Slack bot", response: "Next", status: .complete)
        )
        #expect(started.isOngoingPluginCreator)
        #expect(!started.isUnusedPluginCreator)
    }

    @MainActor
    @Test func retirePluginCreatorTabsRemovesCreateTabsBeforePluginOpens() {
        let store = ChatSessionStore()
        let creatorID = store.openOrFocusPluginCreator()
        _ = store.openOrFocusPlugin(pluginID: "slack-connector-1", surface: .thread, title: "/slack-connector-1")
        #expect(store.tabs.contains { $0.id == creatorID })
        store.retirePluginCreatorTabs()
        #expect(store.tabs.contains { $0.id == creatorID } == false)
        #expect(store.tabs.contains { $0.pluginID == "slack-connector-1" })
        #expect(store.tabs.contains(where: \.isPluginCreator) == false)
    }

    @MainActor
    @Test func factoryProgressListsSkillAfterAgentPluginSpec() {
        let ids = PluginCreationController.factoryProgressStepOrder.map(\.id)
        #expect(ids == ["credentials", "spec", "docs", "skill", "factory", "review", "trial"])
        #expect(ids.firstIndex(of: "spec")! < ids.firstIndex(of: "skill")!)
        #expect(ids.firstIndex(of: "credentials")! < ids.firstIndex(of: "spec")!)
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

    @Test func pluginCreatorKeepsPluginsTabTitleWhenReseeded() {
        var tab = ChatTab.pluginCreator()
        tab.title = PluginSpecProcession.creatorTabTitle(from: "connect to slack and send receive messages")
        let reseeded = ChatTab.pluginCreator(existing: tab)
        #expect(reseeded.title == PluginSpecProcession.pluginsTabTitle)
    }

    @Test func pluginCreatorTabTitleStaysPluginsAfterClaimedOutcome() {
        var tab = ChatTab.pluginCreator()
        #expect(tab.title == PluginSpecProcession.pluginsTabTitle)
        _ = tab.applyCreatorUtterance("connect to slack and send receive messages")
        #expect(tab.title == PluginSpecProcession.pluginsTabTitle)
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
