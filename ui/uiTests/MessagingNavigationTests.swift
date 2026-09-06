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

        await session.openConnector(pluginID: "slack-bot", autoOpenMostRecent: true)
        #expect(session.selectedThreadID == thread.id)

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
}
