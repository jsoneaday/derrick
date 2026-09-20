import AppKit
import Combine
import DBRepository
import Foundation
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
    @Published private(set) var recordedHostUIRoot: HostUINode?

    private var repository: DBRepository?
    private var cancellables = Set<AnyCancellable>()
    private lazy var connectorRuntime = ConnectorMessagingRuntime()
    private var inboundObserver: DerrickDarwinNotifyObserver?
    private var hostUIPresentObserver: DerrickDarwinNotifyObserver?
    let inboundBannerService = MessagingInboundBannerService()
    private var connectorCommandGeneration = 0

    init() {
        catalog = MessagingCatalogStore()
        session = MessagingSessionStore()
        catalog.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        inboundBannerService.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        inboundObserver = DerrickDarwinNotifyObserver(
            darwinName: DerrickMessagingInboundSignal.darwinName,
            localName: DerrickMessagingInboundSignal.localNotificationName
        ) { [weak self] in
            Task { @MainActor in
                await self?.refreshFromDaemonInbound()
            }
        }
        inboundObserver?.start()
        hostUIPresentObserver = DerrickDarwinNotifyObserver(
            darwinName: HostUIPresentWake.darwinName,
            localName: HostUIPresentWake.localNotificationName
        ) { [weak self] in
            let pluginID = HostUIPresentWake.takePendingPluginID()
            Task { await self?.refreshHostUIRoot(matching: pluginID) }
        }
        hostUIPresentObserver?.start()
        NotificationCenter.default.publisher(for: PluginFactoryDeletionSignal.didDeletePluginNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let pluginID = note.userInfo?[PluginFactoryDeletionSignal.pluginIDKey] as? String
                let fullyRemoved = note.userInfo?[PluginFactoryDeletionSignal.fullyRemovedKey] as? Bool ?? false
                guard fullyRemoved, let pluginID else { return }
                Task { await self?.refreshHostUIRoot(matching: pluginID) }
            }
            .store(in: &cancellables)
    }

    var inboundBanner: String? { inboundBannerService.bannerText }
    var inboundBannerPluginID: String? { inboundBannerService.bannerPluginID }
    var inboundBannerThreadID: String? { inboundBannerService.bannerThreadID }

    var connectors: [MessagingConnectorDTO] { catalog.connectors }
    var threads: [MessagingThreadDTO] { session.threads }
    var tabs: [MessagingTab] { session.tabs }
    var selectedPluginID: String? { session.selectedPluginID }
    var selectedThreadID: String? { session.selectedThreadID }
    var selectedReplyParentVendorMessageID: String? { session.selectedReplyParentVendorMessageID }
    var isViewingReplyThread: Bool { session.isViewingReplyThread }
    var replyThreadTitle: String { session.replyThreadTitle }
    var visibleMessages: [MessagingMessageDTO] { session.visibleMessages }
    var visibleReplyMessages: [MessagingMessageDTO] { session.visibleReplyMessages }
    var lastReplyPreviewByParentID: [String: String] { session.lastReplyPreviewByParentID }

    func agentWorkStatus(forParent parentID: String?) -> String? {
        session.agentWorkStatus(forParent: parentID)
    }
    var replyThreadWarning: String? { session.replyThreadWarning }
    var scrollToBottomToken: Int { session.scrollToBottomToken }
    var scrollAnchorID: String? { session.scrollAnchorID }
    var showJumpToLatest: Bool { session.showJumpToLatest }
    var showNewMessagesPill: Bool { session.showNewMessagesPill }
    var lastError: String? { session.lastError ?? catalog.lastError }
    var hostUIRoot: HostUINode {
        if let recordedHostUIRoot {
            return recordedHostUIRoot
        }
        // Template only until the plugin presents a tree. A recorded present is never replaced.
        return (try? HostUILibraryStore.messagingInbox())
            ?? HostUINode(
                element: "screen",
                config: ["holds": .string("arbitrary")]
            )
    }
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

    func setConnectorSyncing(_ syncing: Bool) {
        isConnectorSyncing = syncing
    }

    var connectorCommandID: Int { connectorCommandGeneration }

    @discardableResult
    func beginConnectorCommand() -> Int {
        connectorCommandGeneration += 1
        session.setLastError(nil)
        return connectorCommandGeneration
    }

    func configure(repository: DBRepository) async {
        self.repository = repository
        await HostUIPresentStore.shared.configure(persister: repository)
        await catalog.configure(repository: repository)
        session.configure(repository: repository, catalog: catalog)
        session.dropSelectionIfConnectorMissing()
        await refreshHostUIRoot(matching: nil)
    }

    func setWorkspaceActive(_ active: Bool) {
        session.setWorkspaceActive(active)
        publishForegroundPresence()
    }

    func publishForegroundPresence(isFrontmost: Bool? = nil) {
        DerrickMessagingForegroundPresence.sync(
            isMessagingWorkspace: session.isMessagingWorkspace,
            pluginID: session.selectedPluginID,
            vendorThreadID: session.selectedThread?.vendorThreadID,
            parentVendorMessageID: session.selectedReplyParentVendorMessageID,
            isFrontmost: isFrontmost ?? NSApp.isActive
        )
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
    func openConnector(pluginID: String, autoOpenMostRecent: Bool = true) async -> Bool {
        guard PluginFactoryCreateInput.ConnectorVendor.isEnabledMessagingPluginID(pluginID) else {
            return false
        }
        session.selectConnector(pluginID: pluginID)
        session.setLastError(nil)
        await refreshHostUIRoot(matching: pluginID)
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
            MessagingPollRefreshService.requestPoll()
        }
        await session.openConnector(
            pluginID: pluginID,
            autoOpenMostRecent: autoOpenMostRecent || hostUIRoot.opensFirstConversation
        )
        guard session.selectedPluginID == pluginID else { return false }
        publishForegroundPresence()
        primeInboundMessageIDs()
        if repository != nil, catalog.contains(pluginID: pluginID) {
            let generation = beginConnectorCommand()
            setConnectorSyncing(true)
            Task { @MainActor in
                await connectorRuntime.bootstrap(
                    pluginID: pluginID,
                    store: self,
                    session: session,
                    generation: generation
                )
            }
        }
        return true
    }

    /// Opens a specific conversation from a notification tap.
    func openConversation(
        pluginID: String,
        threadID: String,
        parentVendorMessageID: String? = nil
    ) async -> Bool {
        guard PluginFactoryCreateInput.ConnectorVendor.isEnabledMessagingPluginID(pluginID) else {
            return false
        }
        session.selectConnector(pluginID: pluginID)
        await catalog.reloadFromFactory(preservingPluginIDs: [pluginID])
        await session.openConnector(pluginID: pluginID, autoOpenMostRecent: false)
        guard session.threads.contains(where: { $0.id == threadID }) else { return false }
        await session.selectThread(id: threadID)
        if let parent = parentVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parent.isEmpty {
            await session.openReplyThread(parentVendorMessageID: parent)
        }
        let opened = session.selectedPluginID == pluginID && session.selectedThreadID == threadID
        if opened {
            publishForegroundPresence()
            primeInboundMessageIDs()
        }
        return opened
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
        guard selectedPluginID == pluginID else { return }
        let generation = beginConnectorCommand()
        await connectorRuntime.bootstrap(
            pluginID: pluginID,
            store: self,
            session: session,
            generation: generation
        )
    }

    /// Paint an outbound bubble immediately (call from the submit tap, before `Task`).
    @discardableResult
    func beginOptimisticSend(text: String, parentVendorMessageID: String?) -> String? {
        MessagingOptimisticSendService.begin(
            on: session,
            body: text,
            parentVendorMessageID: parentVendorMessageID
        )
    }

    func sendMessage(
        _ text: String,
        parentVendorMessageID: String? = nil,
        optimisticID: String? = nil
    ) async {
        guard let repository,
              let pluginID = selectedPluginID,
              let thread = selectedThread else {
            return
        }
        let pendingID = optimisticID ?? MessagingOptimisticSendService.begin(
            on: session,
            body: text,
            parentVendorMessageID: parentVendorMessageID
        )
        isSending = true
        defer { isSending = false }
        do {
            try await connectorRuntime.send(
                pluginID: pluginID,
                text: text,
                thread: thread,
                parentVendorMessageID: parentVendorMessageID,
                repository: repository,
                store: self,
                session: session
            )
            session.setLastError(nil)
        } catch {
            if let pendingID {
                MessagingOptimisticSendService.cancel(on: session, id: pendingID)
            }
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
            let optimisticID = MessagingOptimisticSendService.begin(
                on: session,
                body: body,
                parentVendorMessageID: nil
            )
            do {
                try await connectorRuntime.send(
                    pluginID: pluginID,
                    text: body,
                    thread: thread,
                    repository: repository,
                    store: self,
                    session: session
                )
                session.setLastError(nil)
                MessagingPollRefreshService.requestPoll()
            } catch {
                if let optimisticID {
                    MessagingOptimisticSendService.cancel(on: session, id: optimisticID)
                }
                throw error
            }
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
            MessagingPollRefreshService.requestPoll()
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
        primeInboundMessageIDs()
        MessagingPollRefreshService.requestPoll()
    }

    func selectThread(id: String) async {
        await session.selectThread(id: id)
        primeInboundMessageIDs()
        publishForegroundPresence()
        MessagingPollRefreshService.requestPoll()
    }

    func openReplyThread(parentVendorMessageID: String) async {
        await MessagingReplyThreadService.open(
            parentVendorMessageID: parentVendorMessageID,
            session: session,
            connectorRuntime: connectorRuntime,
            pluginID: selectedPluginID,
            thread: selectedThread,
            primeInbound: { [weak self] in self?.primeInboundMessageIDs() },
            publishPresence: { [weak self] in self?.publishForegroundPresence() }
        )
    }

    func closeReplyThread() {
        MessagingReplyThreadService.close(
            session: session,
            publishPresence: { [weak self] in self?.publishForegroundPresence() }
        )
    }

    func toggleMuteSelectedThread() async {
        await session.toggleMuteSelectedThread()
    }

    func setChannelDefaultProfile(handle: String?) async {
        await session.setDefaultAgentProfileForSelectedThread(handle: handle)
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
        await MessagingPollRefreshService.refreshFromDaemon(
            session: session,
            catalog: catalog,
            onAfterReload: { [weak self] in
                self?.presentInboundBannerIfNeeded()
            }
        )
    }

    private func visibleInboundMessages() -> [MessagingMessageDTO] {
        (session.visibleMessages + session.visibleReplyMessages)
            .filter { $0.direction == .inbound }
    }

    private func primeInboundMessageIDs() {
        inboundBannerService.prime(visibleInbound: visibleInboundMessages())
    }

    private func presentInboundBannerIfNeeded() {
        _ = inboundBannerService.presentIfNeeded(
            visibleInbound: visibleInboundMessages(),
            isMessagingWorkspace: session.isMessagingWorkspace,
            pluginID: session.selectedPluginID
        )
    }

    func clearInboundBanner() {
        inboundBannerService.clear()
    }

    func refreshHostUIRoot(matching pluginID: String?) async {
        if let pluginID, let selected = selectedPluginID, pluginID != selected {
            return
        }
        guard let selected = selectedPluginID else {
            recordedHostUIRoot = nil
            return
        }
        recordedHostUIRoot = await HostUIPresentStore.shared.root(pluginID: selected)
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
