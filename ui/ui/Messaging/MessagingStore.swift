import Combine
import DBRepository
import Foundation
import Plugin
import Structure

/// Messaging's first paint: the empty catalog vs a specific vendor connector.
enum MessagingConversationLanding: Equatable {
    case catalogRoot
    case vendorConnector(pluginID: String)

    static func resolve(selectedPluginID: String?) -> Self {
        guard let pluginID = selectedPluginID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pluginID.isEmpty
        else {
            return .catalogRoot
        }
        return .vendorConnector(pluginID: pluginID)
    }
}

/// UI facade: catalog and conversation stay separate objects.
@MainActor
final class MessagingStore: ObservableObject {
    let catalog: MessagingCatalogStore
    let session: MessagingSessionStore
    @Published private(set) var isConnectorSyncing = false
    @Published var isSending = false

    private var repository: DBRepository?
    private var cancellables = Set<AnyCancellable>()
    private lazy var connectorRuntime = ConnectorMessagingRuntime()
    private var inboundObserver: DerrickDarwinNotifyObserver?

    init() {
        catalog = MessagingCatalogStore()
        session = MessagingSessionStore()
        catalog.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        inboundObserver = DerrickDarwinNotifyObserver(
            darwinName: DerrickMessagingInboundSignal.darwinName
        ) { [weak self] in
            Task { @MainActor in
                await self?.refreshFromDaemonInbound()
            }
        }
        inboundObserver?.start()
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
    var selectedConnectorDisplayName: String {
        if let selectedConnector {
            return selectedConnector.displayName
        }
        if let selectedPluginID {
            return MessagingCatalogStore.displayName(pluginID: selectedPluginID)
        }
        return "Messaging"
    }
    var conversationLanding: MessagingConversationLanding {
        MessagingConversationLanding.resolve(selectedPluginID: selectedPluginID)
    }
    var selectedThread: MessagingThreadDTO? { session.selectedThread }
    var currentRoute: MessagingRoute { session.currentRoute }
    var isSendOnlyConnector: Bool {
        guard let selectedPluginID else { return false }
        return catalog.isSendOnlyConnector(pluginID: selectedPluginID)
    }
    var supportsThreadDiscovery: Bool {
        guard let selectedPluginID else { return false }
        return catalog.supportsThreadDiscovery(pluginID: selectedPluginID)
    }
    var canPickThread: Bool {
        selectedThread == nil
            && supportsThreadDiscovery
            && !threads.isEmpty
            && selectedConnector?.listening == true
            && !isConnectorSyncing
    }
    var needsThreadDiscovery: Bool {
        selectedThread == nil
            && supportsThreadDiscovery
            && threads.isEmpty
            && selectedConnector?.listening == true
    }
    var canSendInSelectedThread: Bool {
        selectedThread != nil
            && selectedConnector?.listening == true
            && !isSending
            && !isConnectorSyncing
    }
    var canComposeSendOnly: Bool {
        canComposeManualChannel && isSendOnlyConnector
    }
    var canComposeManualChannel: Bool {
        guard selectedThread == nil,
              selectedConnector?.listening == true,
              !isSending,
              !isConnectorSyncing,
              let pluginID = selectedPluginID else {
            return false
        }
        if isSendOnlyConnector {
            return true
        }
        if catalog.supportsPollInbox(pluginID: pluginID),
           !catalog.supportsThreadDiscovery(pluginID: pluginID),
           threads.isEmpty {
            return true
        }
        return false
    }
    /// Legacy alias for manual destination entry (send-only or connectors without thread discovery).
    var canComposeNewChannel: Bool { canComposeManualChannel }

    func setConnectorSyncing(_ syncing: Bool) {
        isConnectorSyncing = syncing
    }

    func configure(repository: DBRepository) async {
        self.repository = repository
        await catalog.configure(repository: repository)
        session.configure(repository: repository, catalog: catalog)
        session.dropSelectionIfConnectorMissing()
    }

    func setWorkspaceActive(_ active: Bool) {
        session.setWorkspaceActive(active)
    }

    func syncConnectorsFromFactory() async {
        let preserving = Set([session.selectedPluginID].compactMap { $0 })
        await catalog.reloadFromFactory(preservingPluginIDs: preserving)
        session.dropSelectionIfConnectorMissing()
    }

    func unreadTotal(for pluginID: String) -> Int {
        catalog.unreadTotal(for: pluginID)
    }

    @discardableResult
    func openConnector(pluginID: String) async -> Bool {
        session.selectConnector(pluginID: pluginID)
        await catalog.reloadFromFactory(preservingPluginIDs: [pluginID])
        if let repository {
            switch await MessagingConnectorCredentials.ensureIfNeeded(
                pluginID: pluginID,
                repository: repository
            ) {
            case .ok:
                break
            case .cancelled:
                return false
            }
            try? await repository.setMessagingConnectorListening(pluginID: pluginID, listening: true)
            await catalog.refreshBadges()
            DerrickMessagingIngressSignal.postPoll()
        }
        await session.openConnector(
            pluginID: pluginID,
            autoOpenMostRecent: !catalog.supportsThreadDiscovery(pluginID: pluginID)
        )
        guard session.selectedPluginID == pluginID else { return false }
        if repository != nil, catalog.contains(pluginID: pluginID) {
            setConnectorSyncing(true)
            Task { @MainActor in
                await connectorRuntime.bootstrap(
                    pluginID: pluginID,
                    store: self,
                    session: session
                )
            }
        }
        return true
    }

    func updateCredentials(pluginID: String) async -> Bool {
        guard let repository else { return false }
        let secrets = await ConnectorCredentialService.secretDescriptors(
            pluginID: pluginID,
            repository: repository
        )
        guard !secrets.isEmpty else { return true }
        return await ConnectorCredentialService.present(
            pluginID: pluginID,
            secrets: secrets,
            mode: .allowPartialUpdate
        ) == .ok
    }

    func refreshConnector(pluginID: String) async {
        guard let repository, selectedPluginID == pluginID else { return }
        await connectorRuntime.bootstrap(
            pluginID: pluginID,
            store: self,
            session: session
        )
    }

    func sendMessage(_ text: String) async {
        guard let repository,
              let pluginID = selectedPluginID,
              let thread = selectedThread else {
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            try await connectorRuntime.send(
                pluginID: pluginID,
                text: text,
                thread: thread,
                repository: repository,
                store: self,
                session: session
            )
            session.setLastError(nil)
        } catch {
            let detail = error.localizedDescription
            session.setLastError(detail)
            Task {
                await ServiceLogRecorder.shared.record(
                    service: "messaging",
                    level: .error,
                    code: "send_failed",
                    message: "Messaging send failed pluginID=\(pluginID) threadID=\(thread.id): \(detail)",
                    detailJSON: Self.messagingDetailJSON(
                        pluginID: pluginID,
                        threadID: thread.id,
                        vendorThreadID: thread.vendorThreadID,
                        text: text,
                        error: detail
                    )
                )
            }
        }
    }

    /// Send-only connectors: create a thread row for the destination ID, then send.
    func sendMessage(toChannel vendorThreadID: String, text: String) async {
        guard let repository, let pluginID = selectedPluginID else { return }
        let channel = vendorThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channel.isEmpty else {
            session.setLastError("Enter a destination ID.")
            return
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        isSending = true
        defer { isSending = false }
        do {
            try await openChannelThread(pluginID: pluginID, channelID: channel, repository: repository)
            guard let thread = session.threads.first(where: { $0.vendorThreadID == channel }) else {
                session.setLastError("Could not open that channel.")
                return
            }
            await session.selectThread(id: thread.id)
            try await connectorRuntime.send(
                pluginID: pluginID,
                text: body,
                thread: thread,
                repository: repository,
                store: self,
                session: session
            )
            session.setLastError(nil)
            DerrickMessagingIngressSignal.postPoll()
        } catch {
            session.setLastError(error.localizedDescription)
        }
    }

    /// Legacy manual destination entry for connectors without thread discovery.
    func connectToChannel(_ vendorThreadID: String) async {
        guard let repository, let pluginID = selectedPluginID else { return }
        let channel = vendorThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channel.isEmpty else {
            session.setLastError("Enter a destination ID.")
            return
        }
        do {
            try await openChannelThread(pluginID: pluginID, channelID: channel, repository: repository)
            await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: true)
            session.setLastError(nil)
            DerrickMessagingIngressSignal.postPoll()
        } catch {
            session.setLastError(error.localizedDescription)
        }
    }

    private func openChannelThread(
        pluginID: String,
        channelID: String,
        repository: DBRepository
    ) async throws {
        try await repository.upsertMessagingThread(
            MessagingThreadDTO(
                pluginID: pluginID,
                vendorThreadID: channelID,
                title: channelID
            )
        )
        await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
    }

    /// Opens a discovered conversation by vendor ID (label is shown in the picker).
    func openDiscoveredThread(vendorThreadID: String) async {
        guard let thread = threads.first(where: { $0.vendorThreadID == vendorThreadID }) else {
            session.setLastError("That conversation is no longer available. Try refreshing the list.")
            return
        }
        await session.selectThread(id: thread.id)
        session.setLastError(nil)
        DerrickMessagingIngressSignal.postPoll()
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

    func refreshFromDaemonInbound() async {
        await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
        if let threadID = selectedThreadID {
            await session.reloadMessagesForThread(id: threadID)
        }
        await catalog.refreshBadges()
    }

    private static func messagingDetailJSON(
        pluginID: String,
        threadID: String,
        vendorThreadID: String?,
        text: String,
        error: String
    ) -> String? {
        let payload: [String: String] = [
            "pluginID": pluginID,
            "threadID": threadID,
            "vendorThreadID": vendorThreadID ?? "",
            "textLength": "\(text.count)",
            "textPreview": String(text.prefix(120)),
            "error": error
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
