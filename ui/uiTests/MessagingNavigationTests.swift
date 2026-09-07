import Foundation
import DBRepository
import Structure
import Testing
@testable import ui

@Suite struct MessagingNavigationTests {
    private func createTestRepository() -> DBRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: "test",
                databaseName: "test",
                databaseDirectoryURL: directory,
                username: "ui",
                password: "ui"
            )
        )
    }

    @Test func landingUsesVendorConnectorWhenPluginIsSelected() {
        #expect(MessagingConversationLanding.resolve(selectedPluginID: nil) == .catalogRoot)
        #expect(MessagingConversationLanding.resolve(selectedPluginID: "  ") == .catalogRoot)
        #expect(
            MessagingConversationLanding.resolve(selectedPluginID: "slack-bot")
                == .vendorConnector(pluginID: "slack-bot")
        )
    }

    @MainActor
    @Test func selectConnectorDoesNotWaitForCatalogBeforeLeavingRoot() {
        let session = MessagingSessionStore()
        #expect(MessagingConversationLanding.resolve(selectedPluginID: session.selectedPluginID) == .catalogRoot)
        session.selectConnector(pluginID: "gmail-connector")
        #expect(
            MessagingConversationLanding.resolve(selectedPluginID: session.selectedPluginID)
                == .vendorConnector(pluginID: "gmail-connector")
        )
        #expect(session.selectedThreadID == nil)
    }

    @MainActor
    @Test func openConnectorCanStayOnVendorInsteadOfAutoOpeningAThread() async throws {
        let repository = createTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-bot", displayName: "Slack Bot")
        )
        let thread = MessagingThreadDTO(
            pluginID: "slack-bot",
            vendorThreadID: "C123",
            title: "#general"
        )
        try await repository.upsertMessagingThread(thread)

        let catalog = MessagingCatalogStore()
        let session = MessagingSessionStore()
        session.configure(repository: repository, catalog: catalog)

        await session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: false)
        #expect(session.selectedPluginID == "slack-bot")
        #expect(session.selectedThreadID == nil)
        #expect(session.threads.map(\.id) == [thread.id])
        #expect(session.tabs.map(\.id) == [thread.id])

        await session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: true)
        #expect(session.selectedThreadID == thread.id)
        #expect(session.tabs.map(\.id) == [thread.id])

        try await repository.pruneMessagingThreads(
            pluginID: "slack-bot",
            keepingVendorThreadIDs: []
        )
        await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
        #expect(session.selectedThreadID == nil)
        #expect(session.threads.isEmpty)
    }

    @MainActor
    @Test func catalogReloadKeepsANewlyOpenedConnectorThatFactoryHasNotListedYet() async throws {
        let repository = createTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")

        let catalog = MessagingCatalogStore()
        await catalog.configure(repository: repository)
        #expect(!catalog.contains(pluginID: "slack-bot"))

        await catalog.reloadFromFactory(preservingPluginIDs: ["slack-bot"])
        #expect(catalog.contains(pluginID: "slack-bot"))

        await catalog.reloadFromFactory(preservingPluginIDs: ["slack-bot"])
        #expect(catalog.contains(pluginID: "slack-bot"))
    }

    @MainActor
    @Test func openingAConversationClearsUnreadAfterMessagingIsActive() async throws {
        let repository = createTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-bot", displayName: "Slack Bot")
        )
        let thread = MessagingThreadDTO(
            pluginID: "slack-bot",
            vendorThreadID: "C123",
            title: "#general"
        )
        try await repository.upsertMessagingThread(thread)
        _ = try await repository.insertMessagingMessage(
            MessagingMessageDTO(
                threadID: thread.id,
                vendorMessageID: "1",
                direction: .inbound,
                sender: "alice",
                body: "b1"
            ),
            incrementUnread: true
        )
        _ = try await repository.insertMessagingMessage(
            MessagingMessageDTO(
                threadID: thread.id,
                vendorMessageID: "2",
                direction: .inbound,
                sender: "alice",
                body: "b2"
            ),
            incrementUnread: true
        )

        let catalog = MessagingCatalogStore()
        let session = MessagingSessionStore()
        session.configure(repository: repository, catalog: catalog)
        await session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: true)
        #expect(session.threads.first?.unreadCount == 2)

        session.setWorkspaceActive(true)
        await session.markVisibleConversationRead()

        #expect(session.threads.first?.unreadCount == 0)
        #expect(session.tabs.first?.unreadCount == 0)
        let stored = try await repository.listMessagingThreads(pluginID: "slack-bot")
        #expect(stored.first?.unreadCount == 0)
    }

    @MainActor
    @Test func inboundRefreshClearsUnreadForTheOpenConversation() async throws {
        let repository = createTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-bot", displayName: "Slack Bot")
        )
        let thread = MessagingThreadDTO(
            pluginID: "slack-bot",
            vendorThreadID: "C123",
            title: "#general"
        )
        try await repository.upsertMessagingThread(thread)

        let catalog = MessagingCatalogStore()
        let session = MessagingSessionStore()
        session.configure(repository: repository, catalog: catalog)
        session.setWorkspaceActive(true)
        await session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: true)
        await session.markVisibleConversationRead()
        #expect(session.threads.first?.unreadCount == 0)

        _ = try await repository.insertMessagingMessage(
            MessagingMessageDTO(
                threadID: thread.id,
                vendorMessageID: "9",
                direction: .inbound,
                sender: "alice",
                body: "hello"
            ),
            incrementUnread: true
        )
        await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
        #expect(session.threads.first?.unreadCount == 1)
        #expect(session.tabs.first?.unreadCount == 1)

        await session.markVisibleConversationRead()
        #expect(session.threads.first?.unreadCount == 0)
        #expect(session.tabs.first?.unreadCount == 0)
    }

    @MainActor
    @Test func openConversationFromNotificationSelectsThatThread() async throws {
        let repository = createTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        let store = MessagingStore()
        await store.configure(repository: repository)
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-bot", displayName: "Slack Bot")
        )
        let general = MessagingThreadDTO(
            pluginID: "slack-bot",
            vendorThreadID: "C123",
            title: "#general"
        )
        let random = MessagingThreadDTO(
            pluginID: "slack-bot",
            vendorThreadID: "C456",
            title: "#random"
        )
        try await repository.upsertMessagingThread(general)
        try await repository.upsertMessagingThread(random)

        let opened = await store.openConversation(pluginID: "slack-bot", threadID: random.id)
        #expect(opened)
        #expect(store.selectedPluginID == "slack-bot")
        #expect(store.selectedThreadID == random.id)
        #expect(Set(store.tabs.map(\.id)) == [general.id, random.id])
        #expect(store.conversationLanding == .vendorConnector(pluginID: "slack-bot"))
    }

    @MainActor
    @Test func multipleConversationsOpenAsTabsAndSelectTheMostRecent() async throws {
        let repository = createTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-bot", displayName: "Slack Bot")
        )
        let general = MessagingThreadDTO(
            pluginID: "slack-bot",
            vendorThreadID: "C123",
            title: "#general",
            lastActivityAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let random = MessagingThreadDTO(
            pluginID: "slack-bot",
            vendorThreadID: "C456",
            title: "#random",
            lastActivityAt: Date(timeIntervalSince1970: 1_000_000)
        )
        try await repository.upsertMessagingThread(general)
        try await repository.upsertMessagingThread(random)

        let catalog = MessagingCatalogStore()
        let session = MessagingSessionStore()
        session.configure(repository: repository, catalog: catalog)

        await session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: false)
        #expect(session.selectedThreadID == nil)
        #expect(session.tabs.map(\.title) == ["#general", "#random"])

        await session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: true)

        #expect(session.tabs.map(\.title) == ["#general", "#random"])
        #expect(session.selectedThreadID == general.id)
    }

    @MainActor
    @Test func openingAReplyThreadDoesNotAddATab() async throws {
        let repository = createTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-bot", displayName: "Slack Bot")
        )
        let general = MessagingThreadDTO(
            pluginID: "slack-bot",
            vendorThreadID: "C123",
            title: "#general"
        )
        try await repository.upsertMessagingThread(general)
        _ = try await repository.insertMessagingMessage(
            MessagingMessageDTO(
                threadID: general.id,
                vendorMessageID: "171.1",
                direction: .outbound,
                sender: "derrick",
                body: "a2",
                replyCount: 1
            ),
            incrementUnread: false
        )

        let catalog = MessagingCatalogStore()
        let session = MessagingSessionStore()
        session.configure(repository: repository, catalog: catalog)
        await session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: true)
        #expect(session.tabs.map(\.title) == ["#general"])

        await session.openReplyThread(parentVendorMessageID: "171.1")
        #expect(session.isViewingReplyThread)
        #expect(session.tabs.map(\.title) == ["#general"])
        #expect(session.visibleMessages.map(\.body) == ["a2"])
        #expect(session.visibleReplyMessages.map(\.body) == ["a2"])
        #expect(session.replyThreadWarning == ConnectorReplyThreadAccessMessage.repliesDidNotLoad)
    }

    @MainActor
    @Test func loadedReplyThreadDoesNotShowAccessWarning() async throws {
        let repository = createTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-bot", displayName: "Slack Bot")
        )
        let general = MessagingThreadDTO(
            pluginID: "slack-bot",
            vendorThreadID: "C123",
            title: "#general"
        )
        try await repository.upsertMessagingThread(general)
        _ = try await repository.insertMessagingMessage(
            MessagingMessageDTO(
                threadID: general.id,
                vendorMessageID: "171.1",
                direction: .outbound,
                sender: "derrick",
                body: "a2",
                replyCount: 1
            ),
            incrementUnread: false
        )
        _ = try await repository.insertMessagingMessage(
            MessagingMessageDTO(
                threadID: general.id,
                vendorMessageID: "171.2",
                direction: .inbound,
                sender: "U2",
                body: "hi this is a thread",
                parentVendorMessageID: "171.1"
            ),
            incrementUnread: false
        )

        let catalog = MessagingCatalogStore()
        let session = MessagingSessionStore()
        session.configure(repository: repository, catalog: catalog)
        await session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: true)
        #expect(session.lastReplyPreviewByParentID["171.1"] == "hi this is a thread")
        await session.openReplyThread(parentVendorMessageID: "171.1")
        #expect(session.visibleReplyMessages.map(\.body) == ["a2", "hi this is a thread"])
        #expect(session.replyThreadWarning == nil)
    }

    @MainActor
    @Test func emptySuccessfulSyncIsDiscoveryStateNotAnError() async throws {
        let repository = createTestRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        let manifestJSON = """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"slack-bot","version":"1.0.0",\
        "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py","role":"connector","messaging_ops":["sync_threads","poll_inbox","send_message"]}}}
        """
        let runtimeJSON = #"{"language":"python","entrypoint":"./app.derrick/plugin.py"}"#
        let guestSource = "print([])"
        var release = PluginFactoryRelease(
            pluginID: "slack-bot",
            version: "1.0.0",
            manifestJSON: manifestJSON,
            runtimeJSON: runtimeJSON,
            guestSource: guestSource,
            compiledArtifact: Data(),
            skillFiles: [:],
            contentHash: try PluginContentHash(hex: String(repeating: "0", count: 64)),
            reviewSummary: "ok"
        )
        release = PluginFactoryRelease(
            pluginID: release.pluginID,
            version: release.version,
            manifestJSON: release.manifestJSON,
            runtimeJSON: release.runtimeJSON,
            guestSource: release.guestSource,
            compiledArtifact: release.compiledArtifact,
            skillFiles: release.skillFiles,
            contentHash: PluginContentHash.hash(files: release.packageFiles()),
            reviewSummary: release.reviewSummary
        )
        try await repository.savePluginFactoryRelease(release)

        let store = MessagingStore()
        await store.configure(repository: repository)
        try await repository.setMessagingConnectorListening(pluginID: "slack-bot", listening: true)
        await store.catalog.refreshBadges()
        await store.session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: false)

        #expect(store.supportsThreadDiscovery)
        #expect(store.threads.isEmpty)
        #expect(store.needsThreadDiscovery)
        #expect(store.lastError == nil)
        #expect(store.conversationLanding == .vendorConnector(pluginID: "slack-bot"))
    }
}
