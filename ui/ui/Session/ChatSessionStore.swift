import Combine
import DBRepository
import DockerRunnerXPC
import Foundation
import LLMAgentClient
import Plugin
import ServiceContracts

struct ChatTab: Identifiable, Hashable {
    let id: String
    var title: String
    var turns: [ChatTurn]
    var isStreaming: Bool

    init(id: String, title: String, turns: [ChatTurn] = [], isStreaming: Bool = false) {
        self.id = id
        self.title = title
        self.turns = turns
        self.isStreaming = isStreaming
    }
}

@MainActor
final class ChatSessionStore: ObservableObject {
    @Published private(set) var tabs: [ChatTab] = []
    @Published var selectedSessionID: String?
    @Published private(set) var recentSessions: [ChatSessionDTO] = []
    @Published var scrollToBottomToken = 0
    @Published var factoryKickoffPrompt: String?

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
                !JobSessionID.isJobSession($0.sessionID) && !FactorySessionID.isFactorySession($0.sessionID)
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
            !JobSessionID.isJobSession($0.sessionID) && !FactorySessionID.isFactorySession($0.sessionID)
        }
    }

    func openNewChat() {
        let id = UUID().uuidString
        let tab = ChatTab(id: id, title: "New chat")
        tabs.append(tab)
        selectedSessionID = id
        persistSessionShell(sessionID: id, title: tab.title)
    }

    func openFactorySession(editing pluginID: String? = nil) {
        let id = FactorySessionID.make()
        let locked = pluginID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = locked.isEmpty ? "Create plugin" : "Change \(locked)"
        adoptFactorySession(
            id: id,
            title: title,
            instructionPluginID: CreatePluginSample.pluginID,
            reusePluginID: locked.isEmpty ? nil : locked,
            goal: locked.isEmpty ? "" : "Change \(locked)"
        )
    }

    func adoptFactorySession(
        id: String,
        title: String,
        instructionPluginID: String,
        reusePluginID: String?,
        goal: String
    ) {
        if !tabs.contains(where: { $0.id == id }) {
            tabs.append(ChatTab(id: id, title: title))
        }
        selectedSessionID = id
        persistSessionShell(sessionID: id, title: title)
        let kickoff = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        factoryKickoffPrompt = kickoff.isEmpty ? "Create a complementary plugin." : kickoff
        Task {
            await pruneFactoryStagingVolumes(keeping: id)
            guard let repository else { return }
            var draft = FactoryPackageDraft(goal: factoryKickoffPrompt ?? "")
            if let reuse = reusePluginID, !reuse.isEmpty {
                draft.pluginID = reuse
                draft.reusePluginID = reuse
            }
            let spec = (try? JSONEncoder().encode(draft)).flatMap { String(data: $0, encoding: .utf8) }
            try? await repository.upsertFactorySession(
                FactorySessionRow(
                    sessionID: id,
                    specJSON: spec,
                    stage: "spec",
                    pluginID: reusePluginID,
                    instructionPluginID: instructionPluginID
                )
            )
        }
    }

    private func pruneFactoryStagingVolumes(keeping sessionID: String) async {
        guard let repository else { return }
        let sessions = (try? await repository.listFactorySessions()) ?? []
        var names = Set<String>()
        for session in sessions where session.sessionID != sessionID {
            names.insert(DerrickNamedVolume.pluginStaging(factoryID: session.sessionID))
            if let spec = session.specJSON,
               let data = spec.data(using: .utf8),
               let draft = try? JSONDecoder().decode(FactoryPackageDraft.self, from: data),
               let workspace = draft.workspaceVolume, !workspace.isEmpty {
                names.insert(workspace)
            }
        }
        await XPCDockerRunner.shared.removeRemovableVolumes(Array(names))
    }

    var isFactorySessionSelected: Bool {
        FactorySessionID.isFactorySession(selectedSessionID)
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
        guard !trimmed.isEmpty else { return }

        tabs[tabIndex].turns.append(ChatTurn(prompt: trimmed, response: ""))
        tabs[tabIndex].isStreaming = true
        updateTitleIfNeeded(sessionID: sessionID, prompt: trimmed, tabIndex: tabIndex)
        scrollToBottomToken += 1

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
                let request = AgentTurnRequest(
                    sessionID: sessionID,
                    prompt: trimmed,
                    apiKey: apiKey,
                    modelJSON: modelJSON
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
        tabs[tabIndex].turns[turnIndex].applyStreamChunk(status: status, chunk: chunkText)
        tabs[tabIndex].turns[turnIndex].status = status
        tabs[tabIndex].turns[turnIndex].toolName = dto.toolName
        if selectedSessionID == sessionID {
            scrollToBottomToken += 1
        }
        if status == .complete, let wizard = PluginHookPresentation.decodeOpenCreateWizard(chunkText) {
            CreatePluginWizardStore.shared.present(goal: wizard.goal)
            return
        }
        if status == .complete, let hook = PluginHookPresentation.decodeOpenFactory(chunkText) {
            adoptFactorySession(
                id: hook.sessionID,
                title: hook.title,
                instructionPluginID: hook.instructionPluginID,
                reusePluginID: hook.reusePluginID,
                goal: hook.goal
            )
        }
    }

    private func updateTitleIfNeeded(sessionID: String, prompt: String, tabIndex: Int) {
        guard tabs[tabIndex].title == "New chat" || tabs[tabIndex].title.isEmpty else { return }
        let title = Self.title(from: prompt)
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

    private static func title(from prompt: String) -> String {
        let collapsed = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 48 { return collapsed }
        return String(collapsed.prefix(48)) + "…"
    }
}
