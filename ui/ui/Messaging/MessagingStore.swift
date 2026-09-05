import Combine
import DBRepository
import Foundation
import Plugin
import Structure

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
    var selectedThread: MessagingThreadDTO? { session.selectedThread }
    var currentRoute: MessagingRoute { session.currentRoute }
    var canSendInSelectedThread: Bool {
        selectedThread != nil
            && selectedConnector?.listening == true
            && !isSending
            && !isConnectorSyncing
    }

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
        await catalog.reloadFromFactory()
        session.dropSelectionIfConnectorMissing()
    }

    func unreadTotal(for pluginID: String) -> Int {
        catalog.unreadTotal(for: pluginID)
    }

    func openConnector(pluginID: String) async {
        if let repository {
            switch await MessagingConnectorCredentials.ensureIfNeeded(
                pluginID: pluginID,
                repository: repository
            ) {
            case .ok:
                break
            case .cancelled:
                return
            }
            try? await repository.setMessagingConnectorListening(pluginID: pluginID, listening: true)
            DerrickMessagingIngressSignal.postPoll()
        }
        await session.openConnector(pluginID: pluginID)
        guard let repository, catalog.contains(pluginID: pluginID) else { return }
        await connectorRuntime.bootstrap(
            pluginID: pluginID,
            store: self,
            session: session
        )
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
