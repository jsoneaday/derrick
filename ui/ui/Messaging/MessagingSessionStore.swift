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

/// Open vendor, conversation tabs (one per channel/DM), and the 100-message viewport.
@MainActor
final class MessagingSessionStore: ObservableObject {
    @Published private(set) var threads: [MessagingThreadDTO] = []
    @Published private(set) var tabs: [MessagingTab] = []
    @Published var selectedPluginID: String?
    @Published var selectedThreadID: String?
    @Published var selectedReplyParentVendorMessageID: String?
    @Published private(set) var visibleMessages: [MessagingMessageDTO] = []
    @Published private(set) var visibleReplyMessages: [MessagingMessageDTO] = []
    @Published private(set) var lastReplyPreviewByParentID: [String: String] = [:]
    @Published var replyThreadWarning: String?
    @Published var scrollToBottomToken = 0
    @Published var scrollAnchorID: String?
    @Published var showJumpToLatest = false
    @Published var showNewMessagesPill = false
    @Published private(set) var lastError: String?
    @Published private(set) var isMessagingWorkspace = false

    /// Local outbound rows shown before Slack ack / poll. Never persisted.
    private var pendingOutboundIDs: Set<String> = []
    private var pendingOutboundByID: [String: MessagingMessageDTO] = [:]

    private var repository: DBRepository?
    private var catalog: MessagingCatalogStore?
    private var hasOlder = false
    private var isNearBottom = true

    var selectedThread: MessagingThreadDTO? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    var isViewingReplyThread: Bool {
        selectedReplyParentVendorMessageID != nil
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
        let becameActive = active && !isMessagingWorkspace
        isMessagingWorkspace = active
        if becameActive {
            Task { await markVisibleConversationRead() }
        }
    }

    /// Selects the vendor immediately so Messaging never paints the empty catalog root first.
    func selectConnector(pluginID: String) {
        if selectedPluginID != pluginID {
            selectedThreadID = nil
            selectedReplyParentVendorMessageID = nil
            tabs = []
            threads = []
            visibleMessages = []
            visibleReplyMessages = []
            replyThreadWarning = nil
            lastError = nil
        }
        selectedPluginID = pluginID
    }

    func clearSelection() {
        selectedPluginID = nil
        selectedThreadID = nil
        selectedReplyParentVendorMessageID = nil
        tabs = []
        threads = []
        visibleMessages = []
        visibleReplyMessages = []
        replyThreadWarning = nil
        lastError = nil
    }

    func openConnector(pluginID: String, autoOpenMostRecent: Bool = true) async {
        selectConnector(pluginID: pluginID)
        await reloadThreads(autoOpenMostRecent: autoOpenMostRecent)
    }

    func selectThread(id: String) async {
        if !tabs.contains(where: { $0.id == id }),
           let thread = threads.first(where: { $0.id == id }) {
            tabs.append(MessagingTab(thread: thread))
        }
        selectedThreadID = id
        selectedReplyParentVendorMessageID = nil
        visibleReplyMessages = []
        replyThreadWarning = nil
        await markVisibleConversationRead()
        await loadNewestWindow()
    }

    func openReplyThread(parentVendorMessageID: String) async {
        let parent = parentVendorMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parent.isEmpty else { return }
        selectedReplyParentVendorMessageID = parent
        await loadReplyWindow()
    }

    func closeReplyThread() {
        selectedReplyParentVendorMessageID = nil
        visibleReplyMessages = []
        replyThreadWarning = nil
        Task { await loadNewestWindow() }
    }

    func closeTab(id: String) {
        tabs.removeAll { $0.id == id }
        if selectedThreadID == id {
            selectedThreadID = tabs.last?.id
            selectedReplyParentVendorMessageID = nil
            visibleReplyMessages = []
            replyThreadWarning = nil
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
            setLastError(error.localizedDescription)
        }
    }

    func setDefaultAgentProfileForSelectedThread(handle: String?) async {
        guard let repository, let thread = selectedThread else { return }
        do {
            try await repository.setMessagingThreadDefaultAgentProfile(
                threadID: thread.id,
                handle: handle
            )
            await reloadThreads(autoOpenMostRecent: false)
            refreshSelectedTab()
        } catch {
            setLastError(error.localizedDescription)
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
                limit: MessagingViewport.maxVisibleMessages,
                filter: .channelRoots
            )
            hasOlder = older.count == MessagingViewport.maxVisibleMessages
            guard !older.isEmpty else { return }
            visibleMessages = Array((older + visibleMessages).prefix(MessagingViewport.maxVisibleMessages))
            scrollAnchorID = oldest.id
            showJumpToLatest = true
        } catch {
            setLastError(error.localizedDescription)
        }
    }

    func jumpToLatest() async {
        await loadNewestWindow()
        if selectedReplyParentVendorMessageID != nil {
            await loadReplyWindow()
        }
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
        guard viewing, result.inserted else {
            await catalog?.refreshBadges()
            return
        }
        if result.message.isReply {
            await loadNewestWindow()
            if selectedReplyParentVendorMessageID == result.message.parentVendorMessageID {
                await loadReplyWindow()
            }
            await markVisibleConversationRead()
            await catalog?.refreshBadges()
            return
        }
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
        await markVisibleConversationRead()
        await catalog?.refreshBadges()
    }

    func dropSelectionIfConnectorMissing() {
        guard let selected = selectedPluginID, let catalog else { return }
        guard !catalog.contains(pluginID: selected) else { return }
        selectedPluginID = nil
        selectedThreadID = nil
        selectedReplyParentVendorMessageID = nil
        replyThreadWarning = nil
        clearOptimisticOutbound()
        tabs = []
        threads = []
        visibleMessages = []
        visibleReplyMessages = []
    }

    func setReplyThreadWarning(_ message: String?) {
        replyThreadWarning = message
    }

    func setLastError(_ message: String?) {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = nil
            return
        }
        lastError = WorkerImageFailureDisplay.userFacing(from: message)
    }

    /// Shows an outbound bubble immediately. Dropped when a persisted twin arrives or send fails.
    @discardableResult
    func beginOptimisticOutbound(
        body: String,
        parentVendorMessageID: String?
    ) -> String? {
        guard let threadID = selectedThreadID else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parent = parentVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = MessagingMessageDTO(
            threadID: threadID,
            vendorMessageID: nil,
            direction: .outbound,
            sender: "derrick",
            body: trimmed,
            parentVendorMessageID: (parent?.isEmpty == false) ? parent : nil
        )
        pendingOutboundIDs.insert(message.id)
        pendingOutboundByID[message.id] = message
        applyPendingOverlay()
        scrollToBottomToken += 1
        return message.id
    }

    func cancelOptimisticOutbound(id: String) {
        pendingOutboundIDs.remove(id)
        pendingOutboundByID.removeValue(forKey: id)
        applyPendingOverlay()
    }

    /// After DB reload, drop pending rows that match a persisted outbound (same body/parent).
    func reconcileOptimisticOutbound(against persisted: [MessagingMessageDTO]) {
        guard !pendingOutboundIDs.isEmpty else { return }
        var claimed = Set<String>()
        for message in persisted where message.direction == .outbound {
            guard let id = pendingOutboundIDs.first(where: { pendingID in
                guard !claimed.contains(pendingID),
                      let pending = pendingOutboundByID[pendingID]
                else { return false }
                return Self.isPersistedTwin(message, of: pending)
            }) else { continue }
            claimed.insert(id)
            pendingOutboundIDs.remove(id)
            pendingOutboundByID.removeValue(forKey: id)
        }
    }

    private static func isPersistedTwin(
        _ persisted: MessagingMessageDTO,
        of pending: MessagingMessageDTO
    ) -> Bool {
        guard persisted.direction == .outbound,
              persisted.threadID == pending.threadID,
              persisted.body == pending.body,
              persisted.parentVendorMessageID == pending.parentVendorMessageID,
              abs(persisted.createdAt.timeIntervalSince(pending.createdAt)) < 180
        else { return false }
        // DB pending rows use pending:<uuid> until Slack acks; still twins of UI optimistic rows.
        return true
    }

    private func applyPendingOverlay() {
        guard let threadID = selectedThreadID else { return }
        let channelPending = pendingOutboundByID.values.filter {
            !$0.isReply && $0.threadID == threadID && pendingOutboundIDs.contains($0.id)
        }
        let replyParent = selectedReplyParentVendorMessageID
        let replyPending = pendingOutboundByID.values.filter {
            $0.isReply
                && $0.threadID == threadID
                && $0.parentVendorMessageID == replyParent
                && pendingOutboundIDs.contains($0.id)
        }
        visibleMessages = Self.merging(
            persisted: visibleMessages.filter { !pendingOutboundIDs.contains($0.id) },
            pending: Array(channelPending)
        )
        visibleReplyMessages = Self.merging(
            persisted: visibleReplyMessages.filter { !pendingOutboundIDs.contains($0.id) },
            pending: Array(replyPending)
        )
    }

    static func merging(
        persisted: [MessagingMessageDTO],
        pending: [MessagingMessageDTO]
    ) -> [MessagingMessageDTO] {
        var claimedPersisted = Set<String>()
        let unmatched = pending.filter { p in
            if let twin = persisted.first(where: {
                !claimedPersisted.contains($0.id) && isPersistedTwin($0, of: p)
            }) {
                claimedPersisted.insert(twin.id)
                return false
            }
            return true
        }
        return (persisted + unmatched).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    private func clearOptimisticOutbound() {
        pendingOutboundIDs.removeAll()
        pendingOutboundByID.removeAll()
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
        if selectedReplyParentVendorMessageID != nil {
            await loadReplyWindow()
        }
    }

    func markVisibleConversationRead() async {
        await clearUnreadIfNeeded()
    }

    private func loadNewestWindow() async {
        guard let repository, let threadID = selectedThreadID else {
            visibleMessages = []
            lastReplyPreviewByParentID = [:]
            hasOlder = false
            return
        }
        do {
            let page = try await repository.listMessagingMessages(
                threadID: threadID,
                limit: MessagingViewport.maxVisibleMessages,
                filter: .channelRoots
            )
            reconcileOptimisticOutbound(against: page)
            let channelPending = pendingOutboundByID.values.filter {
                !$0.isReply && $0.threadID == threadID && pendingOutboundIDs.contains($0.id)
            }
            visibleMessages = Self.merging(persisted: page, pending: Array(channelPending))
            hasOlder = page.count == MessagingViewport.maxVisibleMessages
            isNearBottom = true
            showJumpToLatest = false
            showNewMessagesPill = false
            scrollToBottomToken += 1
            let parentIDs = page.compactMap { message -> String? in
                guard message.replyCount > 0 else { return nil }
                return message.vendorMessageID
            }
            lastReplyPreviewByParentID = try await repository.latestReplyPreviews(
                threadID: threadID,
                parentVendorMessageIDs: parentIDs
            )
        } catch {
            setLastError(error.localizedDescription)
        }
    }

    private func loadReplyWindow() async {
        guard let repository,
              let threadID = selectedThreadID,
              let parent = selectedReplyParentVendorMessageID
        else {
            visibleReplyMessages = []
            replyThreadWarning = nil
            return
        }
        do {
            let page = try await repository.listMessagingMessages(
                threadID: threadID,
                limit: MessagingViewport.maxVisibleMessages,
                filter: .replyThread(parentVendorMessageID: parent)
            )
            reconcileOptimisticOutbound(against: page)
            let replyPending = pendingOutboundByID.values.filter {
                $0.isReply
                    && $0.threadID == threadID
                    && $0.parentVendorMessageID == parent
                    && pendingOutboundIDs.contains($0.id)
            }
            visibleReplyMessages = Self.merging(persisted: page, pending: Array(replyPending))
            if let latestReply = visibleReplyMessages.last(where: { $0.parentVendorMessageID == parent }) {
                lastReplyPreviewByParentID[parent] = latestReply.body
            }
            // Keep parent root replyCount in sync for affordances when DB row lags poll.
            if let idx = visibleMessages.firstIndex(where: { $0.vendorMessageID == parent }) {
                let replyCount = visibleReplyMessages.filter { $0.parentVendorMessageID == parent }.count
                if replyCount > visibleMessages[idx].replyCount {
                    visibleMessages[idx].replyCount = replyCount
                }
            }
            refreshReplyThreadAccessWarning()
            isNearBottom = true
            showJumpToLatest = false
            showNewMessagesPill = false
            scrollToBottomToken += 1
        } catch {
            setLastError(error.localizedDescription)
        }
    }

    private func refreshReplyThreadAccessWarning() {
        guard let parentID = selectedReplyParentVendorMessageID else {
            replyThreadWarning = nil
            return
        }
        let parent = visibleReplyMessages.first(where: { $0.vendorMessageID == parentID })
            ?? visibleMessages.first(where: { $0.vendorMessageID == parentID })
        let hasReplies = visibleReplyMessages.contains(where: { $0.parentVendorMessageID == parentID })
        if let parent, parent.replyCount > 0, !hasReplies {
            replyThreadWarning = ConnectorReplyThreadAccessMessage.repliesDidNotLoad
        } else {
            replyThreadWarning = nil
        }
    }

    private func reloadThreads(autoOpenMostRecent: Bool) async {
        guard let repository, let pluginID = selectedPluginID else {
            threads = []
            tabs = []
            return
        }
        do {
            threads = try await repository.listMessagingThreads(pluginID: pluginID)
            syncConversationTabs()
            if let selectedThreadID, !threads.contains(where: { $0.id == selectedThreadID }) {
                self.selectedThreadID = nil
                selectedReplyParentVendorMessageID = nil
                replyThreadWarning = nil
                visibleMessages = []
                visibleReplyMessages = []
            }
            if autoOpenMostRecent {
                if let latest = threads.first {
                    await selectThread(id: latest.id)
                } else {
                    selectedThreadID = nil
                    selectedReplyParentVendorMessageID = nil
                    replyThreadWarning = nil
                    visibleMessages = []
                    visibleReplyMessages = []
                    tabs = []
                }
            }
        } catch {
            setLastError(error.localizedDescription)
        }
    }

    /// Every conversation the connector listed is a tab. Only the selected tab loads messages.
    private func syncConversationTabs() {
        var next: [MessagingTab] = []
        var seen = Set<String>()
        for tab in tabs {
            if let thread = threads.first(where: { $0.id == tab.id }) {
                next.append(MessagingTab(thread: thread))
                seen.insert(tab.id)
            }
        }
        for thread in threads where !seen.contains(thread.id) {
            next.append(MessagingTab(thread: thread))
        }
        tabs = next
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
            setLastError(error.localizedDescription)
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
