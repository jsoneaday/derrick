import Combine
import DBRepository
import Foundation
import LLMAgentClient
import Structure

enum ChatTabSurface: String, Hashable, Sendable {
    case conversation
    case thread
    case generatedView
    case file
    case image

    init(_ present: PluginPresent) {
        switch present {
        case .conversation: self = .conversation
        case .thread: self = .thread
        case .generatedView: self = .generatedView
        case .file: self = .file
        case .image: self = .image
        }
    }
}

struct ChatTab: Identifiable, Hashable {
    let id: String
    var title: String
    var turns: [ChatTurn]
    var pendingAttachments: [ChatFileAttachment]
    var isStreaming: Bool
    var surface: ChatTabSurface
    var pluginID: String?
    var threadID: String?
    var isPluginCreator: Bool
    var specSession: PluginSpecSession?

    init(
        id: String,
        title: String,
        turns: [ChatTurn] = [],
        pendingAttachments: [ChatFileAttachment] = [],
        isStreaming: Bool = false,
        surface: ChatTabSurface = .conversation,
        pluginID: String? = nil,
        threadID: String? = nil,
        isPluginCreator: Bool = false,
        specSession: PluginSpecSession? = nil
    ) {
        self.id = id
        self.title = title
        self.turns = turns
        self.pendingAttachments = pendingAttachments
        self.isStreaming = isStreaming
        self.surface = surface
        self.pluginID = pluginID
        self.threadID = threadID
        self.isPluginCreator = isPluginCreator
        self.specSession = specSession
    }

    static func pluginRootID(_ pluginID: String) -> String {
        "plugin:\(pluginID)"
    }

    static func pluginThreadID(pluginID: String, threadID: String) -> String {
        "plugin:\(pluginID):thread:\(threadID)"
    }

    static func pluginTabIdentity(_ id: String) -> (pluginID: String, threadID: String?)? {
        let prefix = "plugin:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard !rest.isEmpty else { return nil }
        let marker = ":thread:"
        if let range = rest.range(of: marker) {
            let pluginID = String(rest[..<range.lowerBound])
            let threadID = String(rest[range.upperBound...])
            guard !pluginID.isEmpty, !threadID.isEmpty else { return nil }
            return (pluginID, threadID)
        }
        return (rest, nil)
    }

    /// True when the creator tab has user progress beyond the seeded opening turn.
    var isOngoingPluginCreator: Bool {
        isPluginCreator && turns.count > 1
    }

    /// Unused Create tab — in memory only until the user starts prompting.
    var isUnusedPluginCreator: Bool {
        isPluginCreator && !isOngoingPluginCreator
    }

    /// Recents can restore this tab with no turns; Plugins must still show the creator.
    static func pluginCreator(existing: ChatTab? = nil) -> ChatTab {
        var tab = existing ?? ChatTab(
            id: PluginSpecProcession.newCreatorTabID(),
            title: PluginSpecProcession.pluginsTabTitle,
            isPluginCreator: true,
            specSession: PluginSpecSession()
        )
        if tab.title.isEmpty || tab.title == PluginSpecProcession.creatorTabTitlePrefix
            || tab.title.hasPrefix(PluginSpecProcession.creatorTabTitlePrefix + " - ") {
            tab.title = PluginSpecProcession.pluginsTabTitle
        }
        tab.isPluginCreator = true
        if tab.specSession == nil {
            tab.specSession = PluginSpecSession()
        }
        if tab.turns.isEmpty {
            tab.turns = [
                ChatTurn(
                    prompt: PluginSpecProcession.creatorTabTitlePrefix,
                    response: PluginSpecProcession.openingQuestion,
                    status: .complete
                ),
            ]
        }
        return tab
    }

    mutating func applyCreatorUtterance(_ utterance: String) -> PluginSpecTurn {
        var session = specSession ?? PluginSpecSession()
        let turn = PluginSpecProcession.advance(session: &session, utterance: utterance)
        specSession = session
        let isDocsReview = turn.reply == PluginAccessAskPolicy.reviewingQuestion
        turns.append(
            ChatTurn(
                prompt: utterance,
                response: turn.reply,
                status: isDocsReview ? .thinking : .complete,
                toolName: isDocsReview ? AllowedMCPTool.webSearch.rawValue : nil
            )
        )
        title = PluginSpecProcession.pluginsTabTitle
        return turn
    }

    mutating func applyAccessDiscovery(
        _ auth: ConnectorAuthDiscovery,
        documentationURL: String? = nil
    ) {
        guard var session = specSession, session.ask == .slot(.access) else { return }
        session.accessDiscovery = auth.preferringCallCredential()
        session.draft.needsHumanDocsURL = false
        if let documentationURL, !documentationURL.isEmpty {
            session.draft.documentationURL = documentationURL
        }
        specSession = session
        let reply = PluginSpecProcession.question(for: .slot(.access), session: session)
        guard let last = turns.indices.last else { return }
        turns[last].response = reply
        turns[last].status = .complete
        turns[last].toolName = nil
        isStreaming = false
    }

    mutating func beginAccessDocsReview() {
        isStreaming = true
        guard let last = turns.indices.last else { return }
        turns[last].status = .thinking
        turns[last].toolName = AllowedMCPTool.webSearch.rawValue
    }

    mutating func applyDocsReviewFailed(
        triedURL: String? = nil,
        fromHuman: Bool = false,
        failure: PluginDocsLookupFailure? = nil
    ) {
        guard var session = specSession else { return }
        session.accessDiscovery = nil
        session.draft.needsHumanDocsURL = true
        session.draft.documentationURLFromHuman = fromHuman
        session.draft.docsLookupFailure = failure
        let trimmed = triedURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        session.draft.documentationURL = trimmed.isEmpty ? nil : trimmed
        session.ask = .docsURL
        specSession = session
        let reply = PluginSpecProcession.question(for: .docsURL, session: session)
        guard let last = turns.indices.last else { return }
        turns[last].response = reply
        turns[last].status = .complete
        turns[last].toolName = nil
        isStreaming = false
    }

    mutating func applyDocsReviewProgress(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let last = turns.indices.last else { return }
        turns[last].thought = trimmed
        turns[last].status = .thinking
    }
}

@MainActor
final class ChatSessionStore: ObservableObject {
    @Published private(set) var tabs: [ChatTab] = []
    @Published var selectedSessionID: String?
    @Published private(set) var recentSessions: [ChatSessionDTO] = []
    @Published var scrollToBottomToken = 0
        var onPluginSpecComplete: ((PluginSpecSession) -> Void)?

    private var repository: DBRepository?
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var accessDocsTasks: [String: Task<Void, Never>] = [:]
    private var accessDocsGeneration: [String: Int] = [:]
    private let applicationName = "ui"

    var selectedTab: ChatTab? {
        guard let selectedSessionID else { return nil }
        return tabs.first { $0.id == selectedSessionID }
    }

    var isSelectedTabStreaming: Bool {
        selectedTab?.isStreaming ?? false
    }

    func configure(repository: DBRepository) async {
        self.repository = repository
        await refreshRecents()
        // Drop any tab that was incorrectly bound to a job-isolated session.
        tabs.removeAll { JobSessionID.isJobSession($0.id) }
        if let selected = selectedSessionID, JobSessionID.isJobSession(selected) {
            selectedSessionID = nil
        }
        if tabs.isEmpty {
            if let latest = recentSessions.first(where: {
                !JobSessionID.isJobSession($0.sessionID)
                    && !Self.isUnstartedPluginCreatorSession($0)
            }) {
                selectSession(id: latest.sessionID)
            } else {
                openNewChat()
            }
        } else if selectedSessionID == nil {
            selectedSessionID = tabs.last?.id
        }
    }

    func refreshRecents() async {
        guard let repository else { return }
        let rows = (try? await repository.listRecentChatSessions(
            applicationName: applicationName,
            limit: 20
        )) ?? []
        // Drop legacy Create screens that were saved before the user prompted.
        for session in rows where Self.isUnstartedPluginCreatorSession(session) {
            try? await repository.deleteChatSession(
                applicationName: applicationName,
                sessionID: session.sessionID
            )
        }
        let cleaned = (try? await repository.listRecentChatSessions(
            applicationName: applicationName,
            limit: 5
        )) ?? []
        recentSessions = cleaned.filter {
            !JobSessionID.isJobSession($0.sessionID)
                && !Self.isUnstartedPluginCreatorSession($0)
        }
    }

    func openNewChat() {
        let id = UUID().uuidString
        let tab = ChatTab(id: id, title: "New chat")
        tabs.append(tab)
        selectedSessionID = id
        persistSessionShell(sessionID: id, title: tab.title, tab: tab)
    }

    /// Opens Create plugin. Reuses an unused in-memory Create tab; does not persist until the user prompts.
    @discardableResult
    func openOrFocusPluginCreator() -> String {
        if let existing = tabs.last(where: \.isUnusedPluginCreator) {
            selectedSessionID = existing.id
            return existing.id
        }
        let tab = ChatTab.pluginCreator()
        tabs.append(tab)
        selectedSessionID = tab.id
        return tab.id
    }

    private func sendCreatorUtterance(
        _ utterance: String,
        sessionID: String,
        apiKey: String,
        reviewerModelJSON: String?
    ) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }) else { return }
        var tab = tabs[tabIndex]
        let turn = tab.applyCreatorUtterance(utterance)
        var nextTabs = tabs
        nextTabs[tabIndex] = tab
        tabs = nextTabs
        scrollToBottomToken += 1
        persistSessionShell(sessionID: sessionID, title: tab.title, tab: tab)
        persistCreatorTabTitle(sessionID: sessionID, title: tab.title)
        if case .accessSecret = tab.specSession?.ask {
            presentCreatorCredentialForm(sessionID: sessionID)
        }
        if case .slot(.access) = tab.specSession?.ask,
           tab.specSession?.accessDiscovery == nil,
           tab.specSession?.draft.connect?.klass != .localFiles {
            let vendor = PluginAccessAskPolicy.vendor(from: tab.specSession?.draft.connect) ?? .custom
            let sourceName = VendorDocsLocator.searchSourceName(
                from: tab.specSession?.draft.connect?.detail ?? vendor.displayName
            )
            startAccessDocsReview(
                sessionID: sessionID,
                vendor: vendor,
                sourceName: sourceName,
                documentationURL: tab.specSession?.draft.documentationURL,
                apiKey: apiKey,
                reviewerModelJSON: reviewerModelJSON
            )
        }
        if turn.isComplete, let session = tab.specSession {
            onPluginSpecComplete?(session)
        }
    }

    private func startAccessDocsReview(
        sessionID: String,
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        sourceName: String,
        documentationURL: String?,
        apiKey: String,
        reviewerModelJSON: String?
    ) {
        accessDocsTasks[sessionID]?.cancel()
        let generation = (accessDocsGeneration[sessionID] ?? 0) + 1
        accessDocsGeneration[sessionID] = generation
        if let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }) {
            var tab = tabs[tabIndex]
            tab.beginAccessDocsReview()
            var nextTabs = tabs
            nextTabs[tabIndex] = tab
            tabs = nextTabs
        }
        let providedByHuman = documentationURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        accessDocsTasks[sessionID] = Task { @MainActor in
            let review = await PluginCreatorAccessDocsReview.discover(
                vendor: vendor,
                sourceName: sourceName,
                documentationURL: documentationURL,
                sessionID: sessionID,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                reviewerModelJSON: reviewerModelJSON,
                onProgress: { message in
                    Task { @MainActor in
                        self.applyCreatorDocsReviewProgress(
                            sessionID: sessionID,
                            message: message
                        )
                    }
                }
            )
            guard !Task.isCancelled, accessDocsGeneration[sessionID] == generation else { return }
            accessDocsTasks[sessionID] = nil
            if PluginAccessAskPolicy.docsReviewSucceeded(
                failure: review.failure,
                auth: review.auth
            ) {
                applyCreatorAccessDiscovery(
                    sessionID: sessionID,
                    auth: review.auth,
                    documentationURL: review.documentationURL
                )
            } else {
                applyCreatorDocsReviewFailed(
                    sessionID: sessionID,
                    triedURL: review.documentationURL ?? documentationURL,
                    fromHuman: providedByHuman,
                    failure: review.failure
                )
            }
        }
    }

    func applyCreatorDocsReviewProgress(sessionID: String, message: String) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }) else { return }
        var tab = tabs[tabIndex]
        tab.applyDocsReviewProgress(message)
        var nextTabs = tabs
        nextTabs[tabIndex] = tab
        tabs = nextTabs
    }

    func applyCreatorAccessDiscovery(
        sessionID: String,
        auth: ConnectorAuthDiscovery,
        documentationURL: String? = nil
    ) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }) else { return }
        var tab = tabs[tabIndex]
        tab.applyAccessDiscovery(auth, documentationURL: documentationURL)
        var nextTabs = tabs
        nextTabs[tabIndex] = tab
        tabs = nextTabs
        scrollToBottomToken += 1
    }

    func applyCreatorDocsReviewFailed(
        sessionID: String,
        triedURL: String? = nil,
        fromHuman: Bool = false,
        failure: PluginDocsLookupFailure? = nil
    ) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }) else { return }
        var tab = tabs[tabIndex]
        tab.applyDocsReviewFailed(triedURL: triedURL, fromHuman: fromHuman, failure: failure)
        var nextTabs = tabs
        nextTabs[tabIndex] = tab
        tabs = nextTabs
        scrollToBottomToken += 1
    }

    private func presentCreatorCredentialForm(sessionID: String) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }),
              var session = tabs[tabIndex].specSession,
              session.ask == .accessSecret
        else { return }
        let secrets = PluginAccessAskPolicy.collectableSecrets(session.accessDiscovery).map(\.descriptor)
        guard !secrets.isEmpty else { return }
        if session.reservedPluginID == nil {
            var skill = session.draft.asSkillDraft()
            PluginSkillDraftPlanner.applyGoal(
                skill.goal,
                to: &skill,
                existingPluginIDs: PluginFactoryListStore.shared.pluginIDs
            )
            session.reservedPluginID = try? skill.normalizedPluginID()
            var tab = tabs[tabIndex]
            tab.specSession = session
            var next = tabs
            next[tabIndex] = tab
            tabs = next
        }
        guard let pluginID = session.reservedPluginID, !pluginID.isEmpty else { return }
        let prompt = PluginAccessAskPolicy.credentialFormPrompt(discovery: session.accessDiscovery)
        Task { @MainActor in
            let result = await ConnectorCredentialService.present(
                pluginID: pluginID,
                secrets: secrets,
                mode: .requireMissing,
                prompt: prompt
            )
            self.finishCreatorCredentialForm(sessionID: sessionID, result: result)
        }
    }

    private func finishCreatorCredentialForm(sessionID: String, result: ConnectorCredentialService.Result) {
        guard result == .ok,
              let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }),
              var session = tabs[tabIndex].specSession
        else { return }
        let turn = PluginSpecProcession.completeAccessCollection(session: &session)
        var tab = tabs[tabIndex]
        tab.specSession = session
        if let last = tab.turns.indices.last {
            tab.turns[last].response = turn.reply
            tab.turns[last].status = .complete
            tab.turns[last].toolName = nil
        }
        var next = tabs
        next[tabIndex] = tab
        tabs = next
        scrollToBottomToken += 1
        persistSessionShell(sessionID: sessionID, title: tab.title, tab: tab)
        persistCreatorTabTitle(sessionID: sessionID, title: tab.title)
        if turn.isComplete {
            onPluginSpecComplete?(session)
        }
    }

    private func persistCreatorTabTitle(sessionID: String, title: String) {
        guard let repository else { return }
        Task {
            try? await repository.updateChatSessionTitle(
                applicationName: applicationName,
                sessionID: sessionID,
                title: title
            )
            await refreshRecents()
        }
    }

    func selectSession(id: String) {
        guard !JobSessionID.isJobSession(id) else {
            openNewChat()
            return
        }
        if !tabs.contains(where: { $0.id == id }) {
            let session = recentSessions.first(where: { $0.sessionID == id })
            let title = session.map(displayTitle(for:)) ?? "Chat"
            var tab = tab(from: session, id: id, title: title)
            if let identity = ChatTab.pluginTabIdentity(id), identity.threadID != nil {
                _ = openOrFocusPlugin(
                    pluginID: identity.pluginID,
                    surface: .thread,
                    title: "/\(identity.pluginID)"
                )
                return
            }
            if let pluginID = tab.pluginID,
               tab.threadID != nil,
               tab.surface == .thread {
                _ = openOrFocusPlugin(
                    pluginID: pluginID,
                    surface: .thread,
                    title: "/\(pluginID)"
                )
                return
            }
            if PluginSpecProcession.isCreatorTabID(id) || tab.isPluginCreator {
                // Never restore an unused Create into Chat — those stay in-memory only.
                if session.map(Self.isUnstartedPluginCreatorSession) ?? true {
                    openNewChat()
                    return
                }
                tab = ChatTab.pluginCreator(existing: tab)
            }
            tabs.append(tab)
        } else if let index = tabs.firstIndex(where: { $0.id == id }) {
            if let identity = ChatTab.pluginTabIdentity(id), identity.threadID != nil {
                _ = openOrFocusPlugin(
                    pluginID: identity.pluginID,
                    surface: .thread,
                    title: "/\(identity.pluginID)"
                )
                return
            }
            if let pluginID = tabs[index].pluginID,
               tabs[index].threadID != nil,
               tabs[index].surface == .thread {
                _ = openOrFocusPlugin(
                    pluginID: pluginID,
                    surface: .thread,
                    title: "/\(pluginID)"
                )
                return
            }
            if PluginSpecProcession.isCreatorTabID(id) || tabs[index].isPluginCreator {
                tabs[index] = ChatTab.pluginCreator(existing: tabs[index])
            }
        }
        selectedSessionID = id
    }

    /// Opens or focuses a Chat tab for `/plugin-id` (connector or standard).
    @discardableResult
    func openOrFocusPlugin(pluginID: String, surface: ChatTabSurface, title: String? = nil) -> String {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = ChatTab.pluginRootID(trimmed)
        if let existing = tabs.first(where: { $0.id == id })
            ?? tabs.first(where: { $0.pluginID == trimmed && $0.threadID == nil }) {
            selectedSessionID = existing.id
            return existing.id
        }
        let tabTitle = title ?? "/\(trimmed)"
        let tab = ChatTab(
            id: id,
            title: tabTitle,
            surface: surface,
            pluginID: trimmed
        )
        tabs.append(tab)
        selectedSessionID = id
        persistSessionShell(sessionID: id, title: tabTitle, tab: tab)
        return id
    }

    /// Opens or focuses a Chat tab for a connector thread (notifications, picker).
    @discardableResult
    func openOrFocusThread(
        pluginID: String,
        threadID: String,
        title: String? = nil
    ) -> String {
        let plugin = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = ChatTab.pluginThreadID(pluginID: plugin, threadID: thread)
        if let existing = tabs.first(where: { $0.id == id })
            ?? tabs.first(where: { $0.pluginID == plugin && $0.threadID == thread }) {
            selectedSessionID = existing.id
            return existing.id
        }
        let tabTitle = title ?? "/\(plugin)"
        let tab = ChatTab(
            id: id,
            title: tabTitle,
            surface: .thread,
            pluginID: plugin,
            threadID: thread
        )
        tabs.append(tab)
        selectedSessionID = id
        persistSessionShell(sessionID: id, title: tabTitle, tab: tab)
        return id
    }

    func closeTab(id: String) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        accessDocsTasks[id]?.cancel()
        accessDocsTasks[id] = nil
        accessDocsGeneration[id] = nil
        tabs.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = tabs.last?.id
            if tabs.isEmpty {
                openNewChat()
            }
        }
    }

    /// Removes Create-plugin tabs (and their saved sessions) after a successful build opens the plugin.
    func retirePluginCreatorTabs() {
        let creators = tabs.filter(\.isPluginCreator)
        guard !creators.isEmpty else { return }
        let ids = creators.map(\.id)
        for id in ids {
            activeTasks[id]?.cancel()
            activeTasks[id] = nil
            accessDocsTasks[id]?.cancel()
            accessDocsTasks[id] = nil
            accessDocsGeneration[id] = nil
        }
        tabs.removeAll { ids.contains($0.id) }
        if let selected = selectedSessionID, ids.contains(selected) {
            selectedSessionID = tabs.last?.id
        }
        guard let repository else { return }
        Task {
            for id in ids {
                try? await repository.deleteChatSession(
                    applicationName: applicationName,
                    sessionID: id
                )
            }
            await refreshRecents()
        }
    }

    /// Drops Chat tabs for a deleted plugin (root + thread tabs).
    func closeTabs(forPluginID pluginID: String) {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let matching = tabs.filter { tab in
            tab.pluginID == trimmed
                || ChatTab.pluginTabIdentity(tab.id)?.pluginID == trimmed
        }
        for tab in matching {
            closeTab(id: tab.id)
        }
        Task { await refreshRecents() }
    }

    func sendPrompt(
        _ prompt: String,
        apiKey: String,
        profileHandle: String,
        reviewerModelJSON: String? = nil,
        onError: @escaping (String) -> Void
    ) {
        if let selected = selectedSessionID, JobSessionID.isJobSession(selected) {
            openNewChat()
        }
        guard let sessionID = selectedSessionID,
              !JobSessionID.isJobSession(sessionID),
              let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }),
              !tabs[tabIndex].isStreaming
        else {
            return
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = tabs[tabIndex].pendingAttachments
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        if tabs[tabIndex].isPluginCreator {
            sendCreatorUtterance(
                trimmed,
                sessionID: sessionID,
                apiKey: apiKey,
                reviewerModelJSON: reviewerModelJSON
            )
            return
        }

        guard let resolved = AgentProfileStore.shared.resolveProfile(
            explicitHandle: profileHandle,
            message: trimmed
        ) else {
            onError("Choose a profile and enter a message.")
            return
        }
        let profile = resolved.profile
        let profilePrompt = resolved.prompt
        let model = (try? JSONDecoder().decode(LLMModelChoice.self, from: profile.modelJSON))
            ?? .defaultHelperModel
        let thinking = profile.thinkingJSON.flatMap {
            try? JSONDecoder().decode(ModelThinkingOption.self, from: $0)
        } ?? model.defaultThinkingOption

        tabs[tabIndex].pendingAttachments = []
        tabs[tabIndex].turns.append(
            ChatTurn(prompt: trimmed, attachments: attachments, response: "")
        )
        tabs[tabIndex].isStreaming = true
        updateTitleIfNeeded(
            sessionID: sessionID,
            prompt: profilePrompt,
            attachments: attachments,
            tabIndex: tabIndex
        )
        scrollToBottomToken += 1

        let stagedRoot = try? ChatFileAttachmentStager.defaultRootDirectory()
        let agentPrompt = ChatFileAttachmentPromptComposer.agentPrompt(
            userText: profilePrompt,
            payloads: ChatFileAttachmentInliner.payloads(
                attachments: attachments,
                rootDirectory: stagedRoot
            )
        )

        let profileContextJSON = try? JSONEncoder().encode(AgentProfileTurnContext(profile: profile))

        activeTasks[sessionID]?.cancel()
        activeTasks[sessionID] = Task {
            defer {
                if let idx = tabs.firstIndex(where: { $0.id == sessionID }) {
                    tabs[idx].isStreaming = false
                }
                activeTasks[sessionID] = nil
            }
            do {
                try await AgentServiceClient.shared.ensureReadyForTurn()
                let modelJSON = try JSONEncoder().encode(model)
                let thinkingJSON = try JSONEncoder().encode(thinking)
                let request = AgentTurnRequest(
                    sessionID: sessionID,
                    prompt: agentPrompt,
                    apiKey: apiKey,
                    modelJSON: modelJSON,
                    thinkingJSON: thinkingJSON,
                    profileContextJSON: profileContextJSON
                )
                let stream = AgentServiceClient.shared.streamTurn(request)
                let streamStarted = Date()
                let streamTimeoutSeconds: TimeInterval = 300
                for try await dto in stream {
                    if Date().timeIntervalSince(streamStarted) > streamTimeoutSeconds {
                        throw AgentServiceClientError.timeout
                    }
                    applyChunk(dto, expectedSessionID: sessionID)
                }
                await refreshRecents()
            } catch {
                if !Task.isCancelled {
                    onError(error.localizedDescription)
                    let failure = LLMFailureClassifier.classify(error, provider: model.provider)
                    LLMFailureReporter.shared.report(failure)
                }
            }
        }
    }

    func applyChunk(_ dto: AgentTurnChunkDTO, expectedSessionID: String) {
        // Always paint onto the tab that started the stream — never follow a remapped job-* session.
        let sessionID = expectedSessionID
        guard let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }),
              !tabs[tabIndex].turns.isEmpty
        else {
            return
        }
        let turnIndex = tabs[tabIndex].turns.count - 1
        let status = AgentResponseStatus(rawValue: dto.status) ?? .thinking
        let chunkText = dto.chunk ?? ""
        tabs[tabIndex].turns[turnIndex].applyStreamChunk(
            status: status,
            chunk: chunkText,
            isProgress: dto.isProgress
        )
        tabs[tabIndex].turns[turnIndex].status = status
        tabs[tabIndex].turns[turnIndex].toolName = dto.toolName
        if selectedSessionID == sessionID {
            scrollToBottomToken += 1
        }
    }

    func appendPendingAttachments(_ attachments: [ChatFileAttachment]) {
        guard let sessionID = selectedSessionID,
              let tabIndex = tabs.firstIndex(where: { $0.id == sessionID })
        else {
            return
        }
        tabs[tabIndex].pendingAttachments.append(contentsOf: attachments)
    }

    func removePendingAttachment(id: String) {
        guard let sessionID = selectedSessionID,
              let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }),
              let attachment = tabs[tabIndex].pendingAttachments.first(where: { $0.id == id })
        else {
            return
        }
        tabs[tabIndex].pendingAttachments.removeAll { $0.id == id }
        if let stager = try? ChatFileAttachmentStager() {
            stager.remove(attachment)
        }
    }

    private func updateTitleIfNeeded(
        sessionID: String,
        prompt: String,
        attachments: [ChatFileAttachment],
        tabIndex: Int
    ) {
        guard tabs[tabIndex].title == "New chat" || tabs[tabIndex].title.isEmpty else { return }
        let title = Self.title(from: prompt, attachments: attachments)
        tabs[tabIndex].title = title
        persistSessionShell(sessionID: sessionID, title: title, tab: tabs[tabIndex])
        Task {
            try? await repository?.updateChatSessionTitle(
                applicationName: applicationName,
                sessionID: sessionID,
                title: title
            )
        }
    }

    private func persistSessionShell(sessionID: String, title: String, tab: ChatTab) {
        guard let repository else { return }
        // Unused Create screens stay in-memory only until the user starts prompting.
        if tab.isUnusedPluginCreator {
            return
        }
        let now = Date.now
        var metadata: [String: String] = ["surface": tab.surface.rawValue]
        if tab.isPluginCreator {
            metadata["pluginCreator"] = "true"
            metadata["pluginCreatorStarted"] = "true"
        }
        if let pluginID = tab.pluginID {
            metadata["pluginID"] = pluginID
        }
        if let threadID = tab.threadID {
            metadata["threadID"] = threadID
        }
        let dto = ChatSessionDTO(
            applicationName: applicationName,
            sessionID: sessionID,
            title: title,
            createdAt: now,
            updatedAt: now,
            metadata: metadata
        )
        Task {
            try? await repository.upsertChatSession(dto)
            await refreshRecents()
        }
    }

    /// Legacy or incomplete Create rows that never received a user prompt.
    private static func isUnstartedPluginCreatorSession(_ session: ChatSessionDTO) -> Bool {
        let isCreator = session.metadata["pluginCreator"] == "true"
            || PluginSpecProcession.isCreatorTabID(session.sessionID)
        guard isCreator else { return false }
        return session.metadata["pluginCreatorStarted"] != "true"
    }

    private func tab(from session: ChatSessionDTO?, id: String, title: String) -> ChatTab {
        let metadata = session?.metadata ?? [:]
        let surface = ChatTabSurface(rawValue: metadata["surface"] ?? "") ?? .conversation
        let pluginID = metadata["pluginID"].flatMap { $0.isEmpty ? nil : $0 }
        let threadID = metadata["threadID"].flatMap { $0.isEmpty ? nil : $0 }
        let isPluginCreator = metadata["pluginCreator"] == "true"
            || PluginSpecProcession.isCreatorTabID(id)
        return ChatTab(
            id: id,
            title: title,
            surface: surface,
            pluginID: pluginID,
            threadID: threadID,
            isPluginCreator: isPluginCreator,
            specSession: isPluginCreator ? PluginSpecSession() : nil
        )
    }

    private func displayTitle(for session: ChatSessionDTO) -> String {
        let trimmed = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Chat" : trimmed
    }

    func cancelSelectedTabStream() {
        guard let sessionID = selectedSessionID else { return }
        activeTasks[sessionID]?.cancel()
        activeTasks[sessionID] = nil
        if let idx = tabs.firstIndex(where: { $0.id == sessionID }) {
            tabs[idx].isStreaming = false
        }
    }

    func clearSelectedTabTurns() {
        guard let sessionID = selectedSessionID,
              let idx = tabs.firstIndex(where: { $0.id == sessionID })
        else { return }
        tabs[idx].turns.removeAll()
    }

    private static func title(from prompt: String, attachments: [ChatFileAttachment]) -> String {
        let collapsed = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = collapsed.isEmpty ? (attachments.first?.originalFilename ?? "Chat") : collapsed
        if source.count <= 48 { return source }
        return String(source.prefix(48)) + "…"
    }
}
