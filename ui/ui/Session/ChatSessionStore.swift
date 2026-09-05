import Combine
import DBRepository
import Foundation
import LLMAgentClient
import Structure

struct ChatTab: Identifiable, Hashable {
    let id: String
    var title: String
    var turns: [ChatTurn]
    var pendingAttachments: [ChatFileAttachment]
    var isStreaming: Bool

    init(
        id: String,
        title: String,
        turns: [ChatTurn] = [],
        pendingAttachments: [ChatFileAttachment] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.title = title
        self.turns = turns
        self.pendingAttachments = pendingAttachments
        self.isStreaming = isStreaming
    }
}

@MainActor
final class ChatSessionStore: ObservableObject {
    @Published private(set) var tabs: [ChatTab] = []
    @Published var selectedSessionID: String?
    @Published private(set) var recentSessions: [ChatSessionDTO] = []
    @Published var scrollToBottomToken = 0

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
        persistSessionShell(sessionID: id, title: tab.title)
    }

    func selectSession(id: String) {
        guard !JobSessionID.isJobSession(id) else {
            openNewChat()
            return
        }
        if !tabs.contains(where: { $0.id == id }) {
            let title = recentSessions.first(where: { $0.sessionID == id }).map(displayTitle(for:))
                ?? "Chat"
            tabs.append(ChatTab(id: id, title: title))
        }
        selectedSessionID = id
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
        model: LLMModelChoice,
        thinking: ModelThinkingOption,
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

        tabs[tabIndex].pendingAttachments = []
        tabs[tabIndex].turns.append(
            ChatTurn(prompt: trimmed, attachments: attachments, response: "")
        )
        tabs[tabIndex].isStreaming = true
        updateTitleIfNeeded(
            sessionID: sessionID,
            prompt: trimmed,
            attachments: attachments,
            tabIndex: tabIndex
        )
        scrollToBottomToken += 1

        let stagedRoot = try? ChatFileAttachmentStager.defaultRootDirectory()
        let agentPrompt = ChatFileAttachmentPromptComposer.agentPrompt(
            userText: trimmed,
            payloads: ChatFileAttachmentInliner.payloads(
                attachments: attachments,
                rootDirectory: stagedRoot
            )
        )

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
                    thinkingJSON: thinkingJSON
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
        persistSessionShell(sessionID: sessionID, title: title)
        Task {
            try? await repository?.updateChatSessionTitle(
                applicationName: applicationName,
                sessionID: sessionID,
                title: title
            )
        }
    }

    private func persistSessionShell(sessionID: String, title: String) {
        guard let repository else { return }
        let now = Date.now
        let dto = ChatSessionDTO(
            applicationName: applicationName,
            sessionID: sessionID,
            title: title,
            createdAt: now,
            updatedAt: now
        )
        Task {
            try? await repository.upsertChatSession(dto)
            await refreshRecents()
        }
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
