import Combine
import DBRepository
import Foundation
import Structure
import SwiftUI

@MainActor
final class PluginCreationController: ObservableObject {
    enum Phase: Equatable {
        case intro
        case goal
        case skill
        case preview
        case discoveringAuth
        case creating
        case collectCredentials(pluginID: String)
        case failed(step: PluginFactoryCreateInput.FailureStep, message: String, technicalDetail: String? = nil)
        case succeeded(pluginID: String, outcome: SuccessOutcome)
    }

    enum SuccessOutcome: Equatable {
        case plugin
        case newsList
    }

    struct ProgressStepState: Identifiable, Equatable {
        enum Status: Equatable {
            case pending
            case active
            case completed
            case failed
        }

        let id: String
        let title: String
        var status: Status
    }

    @Published private(set) var phase: Phase = .intro
    @Published private(set) var statusMessage = ""
    @Published private(set) var progressSteps: [ProgressStepState] = []
    @Published var skillDraft = PluginSkillDraft()
    @Published private(set) var credentialFields: [PluginCredentialFieldPresentation] = []
    @Published var credentialDrafts: [String: String] = [:]

    private var repository: DBRepository?
    private var workflowID: String?
    private var pollAfterSeq = 0
    private var pollTask: Task<Void, Never>?
    private var discoverTask: Task<Void, Never>?
    private var pendingAuth: ConnectorAuthDiscovery?
    private var creationAPIKey: String?
    private var creationReviewerModelJSON: String?
    private var creationSessionID = ""

    deinit {
        pollTask?.cancel()
        discoverTask?.cancel()
    }

    var canContinueFromGoal: Bool {
        !skillDraft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canContinueFromSkill: Bool {
        guard canConfirmPluginName else { return false }
        guard !skillDraft.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !skillDraft.examples.isEmpty else { return false }
        guard skillDraft.examples.allSatisfy({
            !$0.userSays.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.pluginDoes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return false }
        if skillDraft.plannedKind == .newsDigest {
            return !skillDraft.newsTopics.isEmpty && !skillDraft.newsSourceURLs.isEmpty
        }
        return skillDraft.buildBlockedReason == nil
    }

    var canConfirmPluginName: Bool {
        let trimmed = skillDraft.pluginName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if skillDraft.plannedKind == .newsDigest {
            return true
        }
        return (try? PluginID.normalized(trimmed)) != nil
    }

    var canSaveCredentials: Bool {
        ConnectorCredentialSaver.canSave(
            fields: credentialFields,
            drafts: credentialDrafts,
            mode: .requireMissing
        )
    }

    func configure(repository: DBRepository) {
        self.repository = repository
    }

    func skillDraftBinding<T>(_ keyPath: WritableKeyPath<PluginSkillDraft, T>) -> Binding<T> {
        Binding(
            get: { self.skillDraft[keyPath: keyPath] },
            set: { newValue in
                var draft = self.skillDraft
                draft[keyPath: keyPath] = newValue
                self.skillDraft = draft
            }
        )
    }

    func showIntro() {
        cancelPolling()
        discoverTask?.cancel()
        pendingAuth = nil
        phase = .intro
        statusMessage = ""
        progressSteps = []
        credentialFields = []
        credentialDrafts = [:]
        skillDraft = PluginSkillDraft()
    }

    func beginCreate() {
        cancelPolling()
        phase = .goal
        statusMessage = ""
        progressSteps = []
    }

    func continueFromGoal() {
        guard canContinueFromGoal else { return }
        Task { @MainActor in
            await PluginFactoryListStore.shared.reload()
            var draft = skillDraft
            PluginSkillDraftPlanner.applyGoal(
                draft.goal,
                to: &draft,
                existingPluginIDs: PluginFactoryListStore.shared.pluginIDs
            )
            skillDraft = draft
            phase = .skill
        }
    }

    func continueToPreview() {
        guard canContinueFromSkill else { return }
        phase = .preview
    }

    func goBackToGoal() {
        discoverTask?.cancel()
        pendingAuth = nil
        phase = .goal
    }

    func goBackToSkill() {
        discoverTask?.cancel()
        pendingAuth = nil
        phase = .skill
    }

    func addExample() {
        mutateSkillDraft {
            $0.examples.append(PluginSkillDraft.Example(userSays: "", pluginDoes: ""))
        }
    }

    func removeExample(id: String) {
        mutateSkillDraft { $0.examples.removeAll { $0.id == id } }
    }

    func updateExample(id: String, userSays: String? = nil, pluginDoes: String? = nil) {
        mutateSkillDraft { draft in
            guard let index = draft.examples.firstIndex(where: { $0.id == id }) else { return }
            if let userSays { draft.examples[index].userSays = userSays }
            if let pluginDoes { draft.examples[index].pluginDoes = pluginDoes }
        }
    }

    func toggleTrigger(_ trigger: PluginSkillDraft.Trigger) {
        mutateSkillDraft { draft in
            guard draft.isTriggerAvailable(trigger) else { return }
            if draft.triggers.contains(trigger) {
                draft.triggers.remove(trigger)
            } else {
                draft.triggers.insert(trigger)
            }
        }
    }

    func addNewsTopic() {
        let topic = skillDraft.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }
        mutateSkillDraft { draft in
            if !draft.newsTopics.contains(where: { $0.compare(topic, options: .caseInsensitive) == .orderedSame }) {
                draft.newsTopics.append(topic)
            }
        }
    }

    func removeNewsTopic(_ topic: String) {
        mutateSkillDraft { $0.newsTopics.removeAll { $0 == topic } }
    }

    func addNewsTopicFromPreset(_ topic: String) {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateSkillDraft { draft in
            if !draft.newsTopics.contains(trimmed) {
                draft.newsTopics.append(trimmed)
            }
        }
    }

    func addNewsURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = NewsSourceURL.canonicalFetchURL(
            URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
                ?? URL(string: "https://news.google.com/rss")!
        ).absoluteString
        mutateSkillDraft { draft in
            if !draft.newsSourceURLs.contains(normalized) {
                draft.newsSourceURLs.append(normalized)
            }
        }
    }

    func removeNewsURL(_ url: String) {
        mutateSkillDraft { $0.newsSourceURLs.removeAll { $0 == url } }
    }

    private func mutateSkillDraft(_ transform: (inout PluginSkillDraft) -> Void) {
        var draft = skillDraft
        transform(&draft)
        skillDraft = draft
    }

    func confirmPreview(
        sessionID: String,
        helperAPIKey: String?,
        helperReviewerModelJSON: String?
    ) {
        creationSessionID = sessionID
        creationAPIKey = helperAPIKey
        creationReviewerModelJSON = helperReviewerModelJSON

        if skillDraft.plannedKind == .newsDigest {
            startNewsCreation()
            return
        }

        if skillDraft.plannedKind == .messagingConnector {
            phase = .discoveringAuth
            statusMessage = "Reading how this service authenticates…"
            resetProgressSteps()
            startAuthDiscovery()
            return
        }

        startFactoryCreation()
    }

    func saveCredentialsAndFinish() {
        guard case .collectCredentials(let pluginID) = phase else { return }
        do {
            try ConnectorCredentialSaver.persistRequired(
                pluginID: pluginID,
                fields: credentialFields,
                drafts: credentialDrafts
            )
            markProgressCompleted("credentials")
            startFactoryCreation()
        } catch {
            phase = .failed(
                step: .credentials,
                message: "Could not save credentials: \(error.localizedDescription)"
            )
        }
    }

    func retryFromFailure() {
        switch phase {
        case .failed(let step, _, _):
            switch step {
            case .goal: phase = .goal
            case .skill, .news: phase = .skill
            case .preview: phase = .preview
            case .credentials: phase = .preview
            case .build: phase = .preview
            }
        default:
            phase = .intro
        }
    }

    func dismissSuccess() {
        showIntro()
    }

    private func startNewsCreation() {
        let sources = skillDraft.newsSourceURLs.map { url in
            NewsSource(label: URL(string: url)?.host ?? url, url: url)
        }
        let spec = NewsReaderSpec(
            name: skillDraft.pluginName,
            topics: skillDraft.newsTopics,
            sources: sources,
            mode: PluginSkillDraftPlanner.inferNewsMode(from: skillDraft),
            maxCount: 20,
            schedule: .off
        )
        if let blocked = spec.sources.compactMap({ source -> (NewsSource, String)? in
            guard let url = URL(string: source.url),
                  let reason = NewsPaywall.preflightRejection(url: url) else { return nil }
            return (source, reason)
        }).first {
            phase = .failed(
                step: .news,
                message: NewsReaderError.paywalled(url: blocked.0.url, detail: blocked.1).errorDescription
                    ?? "This source is behind a paywall, which is not supported yet."
            )
            return
        }
        phase = .creating
        statusMessage = "Starting news reader in Docker…"
        progressSteps = [
            ProgressStepState(id: "skill", title: "Write SKILL.md", status: .completed),
            ProgressStepState(id: "sources", title: "Check sources", status: .active),
            ProgressStepState(id: "fetch", title: "Run news reader", status: .pending),
        ]
        if spec.mode == .summary {
            progressSteps.append(
                ProgressStepState(id: "summary", title: "Summarize with AI", status: .pending)
            )
        }
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            do {
                let saved = try await NewsReaderStore.shared.create(spec)
                setProgressStep("sources", status: .completed)
                setProgressStep("fetch", status: .completed)
                if spec.mode == .summary {
                    setProgressStep("summary", status: .completed)
                }
                phase = .succeeded(pluginID: saved.id, outcome: .newsList)
            } catch let error as NewsReaderError {
                setProgressStep("sources", status: .failed)
                phase = .failed(
                    step: .news,
                    message: error.localizedDescription,
                    technicalDetail: String(describing: error)
                )
            } catch {
                setProgressStep("sources", status: .failed)
                phase = .failed(step: .news, message: error.localizedDescription)
            }
        }
    }

    private func startFactoryCreation() {
        guard let creationAPIKey, !creationAPIKey.isEmpty else {
            phase = .failed(
                step: .build,
                message: "Add an API key in Settings before creating a plugin."
            )
            return
        }
        do {
            let input = try PluginFactoryCreateInput.makeFromSkillDraft(skillDraft, auth: pendingAuth)
            cancelPolling()
            phase = .creating
            statusMessage = "Building your plugin…"
            resetProgressSteps()
            pollAfterSeq = 0

            pollTask = Task { @MainActor in
                do {
                    let inputJSON = try input.encodedJSON()
                    let handle = try await WorkflowRuntimeClient.shared.startWorkflow(
                        WorkflowStartRequest(
                            kind: .pluginFactoryCreate,
                            sessionID: creationSessionID,
                            agentID: "ui",
                            inputJSON: inputJSON,
                            principal: .agent(sessionID: creationSessionID, agentID: "ui"),
                            helperAPIKey: creationAPIKey,
                            helperReviewerModelJSON: creationReviewerModelJSON
                        )
                    )
                    workflowID = handle.workflowID
                    await pollUntilTerminal()
                } catch {
                    phase = .failed(step: .build, message: error.localizedDescription)
                }
            }
        } catch {
            phase = .failed(step: .skill, message: error.localizedDescription)
        }
    }

    private func resetProgressSteps() {
        progressSteps = [
            ProgressStepState(id: "skill", title: "Write SKILL.md", status: .completed),
            ProgressStepState(id: "docs", title: "Read API docs", status: .pending),
            ProgressStepState(id: "factory", title: "Build guest program", status: .pending),
            ProgressStepState(id: "review", title: "Safety review", status: .pending),
            ProgressStepState(id: "trial", title: "Trial run", status: .pending),
            ProgressStepState(id: "credentials", title: "Save credentials", status: .pending),
        ]
        if skillDraft.plannedKind == .customCapability {
            setProgressStep("docs", status: .completed)
        }
    }

    private func setProgressStep(_ id: String, status: ProgressStepState.Status) {
        guard let index = progressSteps.firstIndex(where: { $0.id == id }) else { return }
        progressSteps[index].status = status
    }

    private func markProgressCompleted(_ id: String) {
        setProgressStep(id, status: .completed)
    }

    private func markProgressActive(_ id: String) {
        setProgressStep(id, status: .active)
    }

    private func markProgressFailed(fromStage stage: String?) {
        switch stage?.lowercased() {
        case "crawl", "docs":
            setProgressStep("docs", status: .failed)
        case "factory", "build":
            markProgressCompleted("docs")
            setProgressStep("factory", status: .failed)
        case "review":
            markProgressCompleted("docs")
            markProgressCompleted("factory")
            setProgressStep("review", status: .failed)
        default:
            setProgressStep("factory", status: .failed)
        }
    }

    private func applyProgressEvent(_ event: WorkflowEventDTO) {
        switch event.kind {
        case "progress":
            switch event.stage {
            case "docs":
                markProgressActive("docs")
            case "factory":
                markProgressCompleted("docs")
                markProgressActive("factory")
            case "complete":
                markProgressCompleted("docs")
                markProgressCompleted("factory")
                markProgressCompleted("review")
                markProgressCompleted("trial")
            default:
                break
            }
        case "log":
            let message = event.message
            if message.contains("draft_started") || message.contains("direct_test") {
                markProgressCompleted("docs")
                markProgressActive("factory")
            }
            if message.contains("review decision=approved") {
                markProgressCompleted("factory")
                markProgressCompleted("review")
                markProgressActive("trial")
            }
            if message.contains("review decision=rejected") || message.contains("review rejected=") {
                markProgressCompleted("factory")
                setProgressStep("review", status: .failed)
            }
        default:
            break
        }
    }

    private func pollUntilTerminal() async {
        guard let workflowID else { return }
        while !Task.isCancelled {
            do {
                let result = try await WorkflowRuntimeClient.shared.pollWorkflowUpdate(
                    WorkflowPollRequest(workflowID: workflowID, afterSeq: pollAfterSeq)
                )
                for event in result.events {
                    pollAfterSeq = max(pollAfterSeq, event.seq)
                    applyProgressEvent(event)
                    if let mapped = WorkflowChatProgress.factoryProgressMessage(from: event.message) {
                        statusMessage = mapped
                    } else if event.kind == "progress",
                              WorkflowChatProgress.shouldSurfaceWorkflowMessage(event.message) {
                        statusMessage = event.message
                    }
                }
                switch result.status {
                case .completed:
                    markProgressCompleted("docs")
                    markProgressCompleted("factory")
                    markProgressCompleted("review")
                    markProgressCompleted("trial")
                    await PluginFactoryListStore.shared.reload()
                    if let pluginID = parseSuccessPluginID(result.resultJSON) {
                        markProgressCompleted("credentials")
                        phase = .succeeded(pluginID: pluginID, outcome: .plugin)
                    } else if let saved = PluginFactoryListStore.shared.releases.first {
                        markProgressCompleted("credentials")
                        phase = .succeeded(pluginID: saved.pluginID, outcome: .plugin)
                    } else {
                        phase = .failed(
                            step: .build,
                            message: "The plugin was not saved. Creation reported success but no release was found.",
                            technicalDetail: result.resultJSON
                        )
                    }
                    cancelPolling()
                    return
                case .failed:
                    let stage = result.events.last(where: { $0.kind == "log" })?.stage
                    markProgressFailed(fromStage: stage)
                    let raw = result.errorMessage ?? "Plugin creation failed."
                    let presentation = PluginFactoryCreateFailureMessage.presentation(raw)
                    phase = .failed(
                        step: PluginFactoryCreateInput.failureStep(forStage: stage),
                        message: presentation.summary,
                        technicalDetail: presentation.technicalDetail
                    )
                    cancelPolling()
                    return
                case .cancelled:
                    markProgressFailed(fromStage: "factory")
                    phase = .failed(
                        step: .build,
                        message: "Plugin creation was cancelled before it finished."
                    )
                    cancelPolling()
                    return
                case .running:
                    break
                }
            } catch {
                phase = .failed(step: .build, message: error.localizedDescription)
                cancelPolling()
                return
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    private func parseSuccessPluginID(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let result = try? JSONDecoder.service.decode(PluginFactoryCreateResult.self, from: data)
        else {
            return nil
        }
        return result.pluginID
    }

    private func startAuthDiscovery() {
        discoverTask?.cancel()
        pendingAuth = nil
        guard let vendor = skillDraft.inferredConnectorVendor else {
            phase = .failed(step: .skill, message: "Could not determine which messaging service this plugin targets.")
            return
        }
        let sessionID = creationSessionID
        let apiKey = creationAPIKey
        let reviewerJSON = creationReviewerModelJSON
        discoverTask = Task { @MainActor in
            var summary = ""
            if vendor.authenticationDocumentationStartURL != nil {
                do {
                    let inputJSON = try ConnectorAuthDiscoverInput(vendor: vendor).encodedJSON()
                    let handle = try await WorkflowRuntimeClient.shared.startWorkflow(
                        WorkflowStartRequest(
                            kind: .connectorAuthDiscover,
                            sessionID: sessionID.isEmpty ? "plugin-wizard" : sessionID,
                            agentID: "ui",
                            inputJSON: inputJSON,
                            principal: .agent(
                                sessionID: sessionID.isEmpty ? "plugin-wizard" : sessionID,
                                agentID: "ui"
                            ),
                            helperAPIKey: apiKey,
                            helperReviewerModelJSON: reviewerJSON
                        )
                    )
                    var after = 0
                    while !Task.isCancelled {
                        let poll = try await WorkflowRuntimeClient.shared.pollWorkflowUpdate(
                            WorkflowPollRequest(workflowID: handle.workflowID, afterSeq: after)
                        )
                        for event in poll.events {
                            after = max(after, event.seq)
                            if event.kind == "progress" {
                                statusMessage = event.message
                            }
                        }
                        if poll.status == .completed {
                            if let json = poll.resultJSON,
                               let data = json.data(using: .utf8),
                               let result = try? JSONDecoder.service.decode(
                                ConnectorAuthDiscoverResult.self,
                                from: data
                               ) {
                                summary = result.crawlSummary
                            }
                            break
                        }
                        if poll.status == .failed || poll.status == .cancelled {
                            break
                        }
                        try? await Task.sleep(nanoseconds: 800_000_000)
                    }
                } catch {
                    summary = ""
                }
            }
            guard !Task.isCancelled else { return }
            let auth = await ConnectorAuthClassifier.classifyOrFallback(
                vendor: vendor,
                crawlSummary: summary,
                apiKey: apiKey,
                reviewerModelJSON: reviewerJSON
            )
            pendingAuth = auth
            if phase == .discoveringAuth {
                presentCredentialsOrFail(auth: auth)
            }
        }
    }

    private func presentCredentialsOrFail(auth: ConnectorAuthDiscovery) {
        guard auth.authScheme.isSupportedInWizard else {
            phase = .failed(
                step: .credentials,
                message: "OAuth connectors are not available yet. Use a bot token or API key."
            )
            return
        }
        guard let pluginID = try? skillDraft.normalizedPluginID() else {
            phase = .skill
            return
        }
        let descriptors = auth.secrets.map(\.descriptor)
        guard !descriptors.isEmpty else {
            phase = .failed(
                step: .credentials,
                message: "Could not determine which credentials this plugin needs."
            )
            return
        }
        PluginSecretHostMirror.syncDevelopmentSecretsToKeychain(
            pluginID: pluginID,
            fields: descriptors
        )
        let fields = PluginCredentialFieldPresentation.presentations(
            for: descriptors,
            pluginID: pluginID
        )
        credentialFields = fields
        credentialDrafts = Dictionary(uniqueKeysWithValues: fields.map { field in
            let env = PluginSecretDevelopmentSource.resolve(pluginID: pluginID, fieldID: field.id) ?? ""
            return (field.id, env)
        })
        statusMessage = auth.setupHint ?? "Enter the credentials this plugin needs. They are stored in Keychain on your Mac."
        phase = .collectCredentials(pluginID: pluginID)
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
