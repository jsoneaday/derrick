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
}

@MainActor
final class ChatSessionStore: ObservableObject {
    @Published private(set) var tabs: [ChatTab] = []
    @Published var selectedSessionID: String?
    @Published private(set) var recentSessions: [ChatSessionDTO] = []
    @Published var scrollToBottomToken = 0
    var onPluginSpecComplete: ((PluginSpecDraft) -> Void)?

    private var repository: DBRepository?
    private var activeTasks: [String: Task<Void, Never>] = [:]
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
            limit: 5
        )) ?? []
        recentSessions = rows.filter {
            !JobSessionID.isJobSession($0.sessionID)
        }
    }

    func openNewChat() {
        let id = UUID().uuidString
        let tab = ChatTab(id: id, title: "New chat")
        tabs.append(tab)
        selectedSessionID = id
        persistSessionShell(sessionID: id, title: tab.title, tab: tab)
    }

    @discardableResult
    func openOrFocusPluginCreator() -> String {
        let id = PluginSpecProcession.creatorTabID
        if let existing = tabs.firstIndex(where: { $0.id == id }) {
            selectedSessionID = tabs[existing].id
            if tabs[existing].specSession == nil {
                tabs[existing].isPluginCreator = true
                tabs[existing].specSession = PluginSpecSession()
            }
            return id
        }
        let opening = PluginSpecProcession.openingQuestion
        let tab = ChatTab(
            id: id,
            title: "Create plugin",
            turns: [
                ChatTurn(
                    prompt: "Create plugin",
                    response: opening,
                    status: .complete
                ),
            ],
            surface: .conversation,
            isPluginCreator: true,
            specSession: PluginSpecSession()
        )
        tabs.append(tab)
        selectedSessionID = id
        persistSessionShell(sessionID: id, title: tab.title, tab: tab)
        return id
    }

    private func sendCreatorUtterance(_ utterance: String, sessionID: String) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = tabs[tabIndex].specSession ?? PluginSpecSession()
        let turn = PluginSpecProcession.advance(session: &session, utterance: utterance)
        tabs[tabIndex].specSession = session
        tabs[tabIndex].turns.append(
            ChatTurn(prompt: utterance, response: turn.reply, status: .complete)
        )
        scrollToBottomToken += 1
        persistSessionShell(sessionID: sessionID, title: tabs[tabIndex].title, tab: tabs[tabIndex])
        if turn.isComplete {
            onPluginSpecComplete?(session.draft)
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
            tabs.append(tab(from: session, id: id, title: title))
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
        tabs.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = tabs.last?.id
            if tabs.isEmpty {
                openNewChat()
            }
        }
    }

    func sendPrompt(
        _ prompt: String,
        apiKey: String,
        profileHandle: String,
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
            sendCreatorUtterance(trimmed, sessionID: sessionID)
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
        let now = Date.now
        var metadata: [String: String] = ["surface": tab.surface.rawValue]
        if tab.isPluginCreator {
            metadata["pluginCreator"] = "true"
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

    private func tab(from session: ChatSessionDTO?, id: String, title: String) -> ChatTab {
        let metadata = session?.metadata ?? [:]
        let surface = ChatTabSurface(rawValue: metadata["surface"] ?? "") ?? .conversation
        let pluginID = metadata["pluginID"].flatMap { $0.isEmpty ? nil : $0 }
        let threadID = metadata["threadID"].flatMap { $0.isEmpty ? nil : $0 }
        let isPluginCreator = metadata["pluginCreator"] == "true"
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
