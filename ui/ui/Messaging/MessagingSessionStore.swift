import Combine
import DBRepository
import Foundation
import Structure

struct MessagingTab: Identifiable, Hashable {
    let id: String
    var title: String
    var unreadCount: Int
    var muted: Bool

    init(thread: MessagingThreadDTO) {
        id = thread.id
        title = thread.title
        unreadCount = thread.unreadCount
        muted = thread.muted
    }
}

/// Open vendor, thread tabs, and the 100-message viewport. Not the connector catalog.
@MainActor
final class MessagingSessionStore: ObservableObject {
    @Published private(set) var threads: [MessagingThreadDTO] = []
    @Published private(set) var tabs: [MessagingTab] = []
    @Published var selectedPluginID: String?
    @Published var selectedThreadID: String?
    @Published private(set) var visibleMessages: [MessagingMessageDTO] = []
    @Published var scrollToBottomToken = 0
    @Published var scrollAnchorID: String?
    @Published var showJumpToLatest = false
    @Published var showNewMessagesPill = false
    @Published private(set) var lastError: String?
    @Published private(set) var isMessagingWorkspace = false

    private var repository: DBRepository?
    private var catalog: MessagingCatalogStore?
    private var hasOlder = false
    private var isNearBottom = true

    var selectedThread: MessagingThreadDTO? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    var currentRoute: MessagingRoute {
        MessagingRoute(
            isMessagingWorkspace: isMessagingWorkspace,
            pluginID: selectedPluginID,
            threadID: selectedThreadID
        )
    }

    func configure(repository: DBRepository, catalog: MessagingCatalogStore) {
        self.repository = repository
        self.catalog = catalog
    }

    func setWorkspaceActive(_ active: Bool) {
        isMessagingWorkspace = active
    }

    func openConnector(pluginID: String) async {
        selectedPluginID = pluginID
        await reloadThreads(autoOpenMostRecent: true)
    }

    func selectThread(id: String) async {
        if !tabs.contains(where: { $0.id == id }),
           let thread = threads.first(where: { $0.id == id }) {
            tabs.append(MessagingTab(thread: thread))
        }
        selectedThreadID = id
        await clearUnreadIfNeeded()
        await loadNewestWindow()
    }

    func closeTab(id: String) {
        tabs.removeAll { $0.id == id }
        if selectedThreadID == id {
            selectedThreadID = tabs.last?.id
            Task { await loadNewestWindow() }
        }
    }

    func toggleMuteSelectedThread() async {
        guard let repository, let thread = selectedThread else { return }
        let muted = !thread.muted
        do {
            try await repository.setMessagingThreadMuted(id: thread.id, muted: muted)
            await reloadThreads(autoOpenMostRecent: false)
            refreshSelectedTab()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setNearBottom(_ nearBottom: Bool) {
        isNearBottom = nearBottom
        if nearBottom {
            showJumpToLatest = false
            showNewMessagesPill = false
        }
    }

    func loadOlderIfNeeded() async {
        guard let repository,
              let threadID = selectedThreadID,
              let oldest = visibleMessages.first,
              hasOlder
        else {
            return
        }
        do {
            let older = try await repository.listMessagingMessages(
                threadID: threadID,
                before: oldest.cursor,
                limit: MessagingViewport.maxVisibleMessages
            )
            hasOlder = older.count == MessagingViewport.maxVisibleMessages
            guard !older.isEmpty else { return }
            visibleMessages = Array((older + visibleMessages).prefix(MessagingViewport.maxVisibleMessages))
            scrollAnchorID = oldest.id
            showJumpToLatest = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func jumpToLatest() async {
        await loadNewestWindow()
        showJumpToLatest = false
        showNewMessagesPill = false
        isNearBottom = true
        scrollToBottomToken += 1
    }

    func applyPersistedInbound(_ result: MessagingPersistResult) async {
        let viewing = currentRoute.isViewing(pluginID: result.thread.pluginID, threadID: result.thread.id)
        if selectedPluginID == result.thread.pluginID {
            await reloadThreads(autoOpenMostRecent: false)
        }
        await catalog?.refreshBadges()
        guard viewing, result.inserted else { return }
        if isNearBottom {
            visibleMessages.append(result.message)
            if visibleMessages.count > MessagingViewport.maxVisibleMessages {
                visibleMessages.removeFirst(visibleMessages.count - MessagingViewport.maxVisibleMessages)
                hasOlder = true
            }
            scrollToBottomToken += 1
        } else {
            showNewMessagesPill = true
            showJumpToLatest = true
        }
        refreshSelectedTab()
        await clearUnreadIfNeeded()
    }

    func dropSelectionIfConnectorMissing() {
        guard let selected = selectedPluginID, let catalog else { return }
        guard !catalog.contains(pluginID: selected) else { return }
        selectedPluginID = nil
        selectedThreadID = nil
        tabs = []
        threads = []
        visibleMessages = []
    }

    func setLastError(_ message: String?) {
        lastError = message
    }

    func reloadThreadsForSelectedConnector(autoOpenMostRecent: Bool) async {
        await reloadThreads(autoOpenMostRecent: autoOpenMostRecent)
    }

    func reloadMessagesForSelectedThread() async {
        await loadNewestWindow()
    }

    func reloadMessagesForThread(id: String) async {
        guard selectedThreadID == id else { return }
        await loadNewestWindow()
    }

    private func reloadThreads(autoOpenMostRecent: Bool) async {
        guard let repository, let pluginID = selectedPluginID else {
            threads = []
            return
        }
        do {
            threads = try await repository.listMessagingThreads(pluginID: pluginID)
            tabs = tabs.compactMap { tab in
                threads.first { $0.id == tab.id }.map(MessagingTab.init)
            }
            if autoOpenMostRecent {
                if let latest = threads.first {
                    await selectThread(id: latest.id)
                } else {
                    selectedThreadID = nil
                    visibleMessages = []
                    tabs = []
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadNewestWindow() async {
        guard let repository, let threadID = selectedThreadID else {
            visibleMessages = []
            hasOlder = false
            return
        }
        do {
            let page = try await repository.listMessagingMessages(
                threadID: threadID,
                limit: MessagingViewport.maxVisibleMessages
            )
            visibleMessages = page
            hasOlder = page.count == MessagingViewport.maxVisibleMessages
            isNearBottom = true
            showJumpToLatest = false
            showNewMessagesPill = false
            scrollToBottomToken += 1
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func clearUnreadIfNeeded() async {
        guard isMessagingWorkspace,
              let repository,
              let threadID = selectedThreadID
        else {
            return
        }
        do {
            try await repository.clearMessagingThreadUnread(id: threadID)
            if let index = threads.firstIndex(where: { $0.id == threadID }) {
                threads[index].unreadCount = 0
            }
            refreshSelectedTab()
            await catalog?.refreshBadges()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshSelectedTab() {
        guard let thread = selectedThread,
              let index = tabs.firstIndex(where: { $0.id == thread.id })
        else {
            return
        }
        tabs[index] = MessagingTab(thread: thread)
    }
}
