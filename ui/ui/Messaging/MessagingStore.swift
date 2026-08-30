import Combine
import DBRepository
import Foundation
import ServiceContracts

/// UI facade: catalog and conversation stay separate objects.
@MainActor
final class MessagingStore: ObservableObject {
    let catalog: MessagingCatalogStore
    let session: MessagingSessionStore
    @Published var isSlackSyncing = false
    @Published var isSending = false

    private var repository: DBRepository?
    private var cancellables = Set<AnyCancellable>()
    private let slackRuntime = MessagingSlackRuntime()
    private var workspaceActive = false

    init() {
        catalog = MessagingCatalogStore()
        session = MessagingSessionStore()
        catalog.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    var connectors: [MessagingConnectorDTO] { catalog.connectors }
    var threads: [MessagingThreadDTO] { session.threads }
    var tabs: [MessagingTab] { session.tabs }
    var selectedPluginID: String? { session.selectedPluginID }
    var selectedThreadID: String? { session.selectedThreadID }
    var visibleMessages: [MessagingMessageDTO] { session.visibleMessages }
    var scrollToBottomToken: Int { session.scrollToBottomToken }
    var scrollAnchorID: String? { session.scrollAnchorID }
    var showJumpToLatest: Bool { session.showJumpToLatest }
    var showNewMessagesPill: Bool { session.showNewMessagesPill }
    var lastError: String? { session.lastError ?? catalog.lastError }
    var selectedConnector: MessagingConnectorDTO? {
        guard let selectedPluginID else { return nil }
        return connectors.first { $0.pluginID == selectedPluginID }
    }
    var selectedThread: MessagingThreadDTO? { session.selectedThread }
    var currentRoute: MessagingRoute { session.currentRoute }
    var canSendInSelectedThread: Bool {
        selectedPluginID == MessagingSlackRuntime.pluginID
            && selectedThread != nil
            && !isSending
            && !isSlackSyncing
    }

    func configure(repository: DBRepository) async {
        self.repository = repository
        await catalog.configure(repository: repository)
        session.configure(repository: repository, catalog: catalog)
        session.dropSelectionIfConnectorMissing()
    }

    func setWorkspaceActive(_ active: Bool) {
        workspaceActive = active
        session.setWorkspaceActive(active)
        guard let repository else { return }
        if active, selectedPluginID == MessagingSlackRuntime.pluginID {
            slackRuntime.resumePolling(store: self, repository: repository)
        } else {
            slackRuntime.stopPolling()
        }
    }

    func syncConnectorsFromFactory() async {
        await catalog.reloadFromFactory()
        session.dropSelectionIfConnectorMissing()
    }

    func unreadTotal(for pluginID: String) -> Int {
        catalog.unreadTotal(for: pluginID)
    }

    func openConnector(pluginID: String) async {
        if let repository {
            _ = await MessagingConnectorCredentials.ensureIfNeeded(
                pluginID: pluginID,
                repository: repository
            )
        }
        await session.openConnector(pluginID: pluginID)
        guard let repository, pluginID == MessagingSlackRuntime.pluginID else { return }
        await slackRuntime.bootstrap(store: self, repository: repository, session: session)
        if workspaceActive {
            slackRuntime.resumePolling(store: self, repository: repository)
        }
    }

    func refreshSlackConnector() async {
        guard let repository, selectedPluginID == MessagingSlackRuntime.pluginID else { return }
        await slackRuntime.bootstrap(store: self, repository: repository, session: session)
    }

    func sendMessage(_ text: String) async {
        guard let repository,
              let thread = selectedThread,
              selectedPluginID == MessagingSlackRuntime.pluginID else {
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            try await slackRuntime.send(
                text: text,
                thread: thread,
                repository: repository,
                store: self,
                session: session
            )
            session.setLastError(nil)
        } catch {
            session.setLastError(error.localizedDescription)
        }
    }

    func selectThread(id: String) async {
        await session.selectThread(id: id)
    }

    func closeTab(id: String) {
        session.closeTab(id: id)
    }

    func toggleMuteSelectedThread() async {
        await session.toggleMuteSelectedThread()
    }

    func setNearBottom(_ nearBottom: Bool) {
        session.setNearBottom(nearBottom)
    }

    func loadOlderIfNeeded() async {
        await session.loadOlderIfNeeded()
    }

    func jumpToLatest() async {
        await session.jumpToLatest()
    }
}
