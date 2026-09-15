import Combine
import DBRepository
import Foundation
import Structure
import SwiftUI

@MainActor
final class PluginCreationController: ObservableObject {
    enum Phase: Equatable {
        case idle
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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusMessage = ""
    @Published private(set) var progressSteps: [ProgressStepState] = []
    @Published var skillDraft = PluginSkillDraft()
    @Published private(set) var completedSpec: PluginSpecDraft?
    @Published private(set) var credentialFields: [PluginCredentialFieldPresentation] = []
    @Published var credentialDrafts: [String: String] = [:]

    private var repository: DBRepository?
    private var workflowID: String?
    private var pollAfterSeq = 0
    private var pollTask: Task<Void, Never>?
    private var discoverTask: Task<Void, Never>?
    private var pendingAuth: ConnectorAuthDiscovery?
    private var reservedPluginID: String?
    private var creationAPIKey: String?
    private var creationReviewerModelJSON: String?
    private var creationSessionID = ""

    deinit {
        pollTask?.cancel()
        discoverTask?.cancel()
    }

    var showsFactoryChrome: Bool {
        switch phase {
        case .idle, .intro, .goal, .skill, .preview:
            return false
        case .discoveringAuth, .creating, .collectCredentials, .failed, .succeeded:
            return true
        }
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
        return skillDraft.buildBlockedReason == nil
    }

    var canConfirmPluginName: Bool {
        let trimmed = skillDraft.pluginName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
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

    func hide() {
        cancelPolling()
        discoverTask?.cancel()
        pendingAuth = nil
        reservedPluginID = nil
        phase = .idle
        statusMessage = ""
        progressSteps = []
        credentialFields = []
        credentialDrafts = [:]
        skillDraft = PluginSkillDraft()
        completedSpec = nil
    }

    func showIntro() {
        cancelPolling()
        discoverTask?.cancel()
        pendingAuth = nil
        reservedPluginID = nil
        phase = .intro
        statusMessage = ""
        progressSteps = []
        credentialFields = []
        credentialDrafts = [:]
        skillDraft = PluginSkillDraft()
        completedSpec = nil
    }

    func beginFromCompletedSpec(
        _ spec: PluginSpecDraft,
        auth: ConnectorAuthDiscovery? = nil,
        pluginID: String? = nil,
        sessionID: String,
        helperAPIKey: String?,
        helperReviewerModelJSON: String?
    ) {
        completedSpec = spec
        pendingAuth = auth?.preferringCallCredential()
        reservedPluginID = pluginID
        var skill = spec.asSkillDraft()
        PluginSkillDraftPlanner.applyGoal(
            skill.goal,
            to: &skill,
            existingPluginIDs: PluginFactoryListStore.shared.pluginIDs
        )
        skillDraft = skill
        confirmPreview(
            sessionID: sessionID,
            helperAPIKey: helperAPIKey,
            helperReviewerModelJSON: helperReviewerModelJSON
        )
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
        reservedPluginID = nil
        phase = .goal
    }

    func goBackToSkill() {
        discoverTask?.cancel()
        pendingAuth = nil
        reservedPluginID = nil
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

        if skillDraft.plannedKind == .messagingConnector {
            if let pendingAuth, pendingAuth.authScheme.isSupportedInWizard {
                startFactoryCreation()
                return
            }
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
            case .skill: phase = .skill
            case .preview: phase = .preview
            case .credentials: phase = .preview
            case .build: phase = .preview
            }
        default:
            phase = .intro
        }
    }

    func dismissSuccess() {
        hide()
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
            let input: PluginFactoryCreateInput
            if let completedSpec {
                input = try PluginFactoryCreateInput.makeFromSpecDraft(
                    completedSpec,
                    auth: pendingAuth?.preferringCallCredential(),
                    existingPluginIDs: PluginFactoryListStore.shared.pluginIDs,
                    pluginID: reservedPluginID
                )
            } else {
                throw PluginCreatorSpecError.notBuildable
            }
            cancelPolling()
            phase = .creating
            statusMessage = "Building your plugin…"
            resetProgressSteps()
            if reservedPluginID != nil {
                markProgressCompleted("credentials")
            }
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
            ProgressStepState(id: "credentials", title: "Save credentials", status: .pending),
            ProgressStepState(id: "factory", title: "Build guest program", status: .pending),
            ProgressStepState(id: "review", title: "Safety review", status: .pending),
            ProgressStepState(id: "trial", title: "Trial run", status: .pending),
        ]
        if skillDraft.plannedKind == .customCapability {
            setProgressStep("docs", status: .completed)
            setProgressStep("credentials", status: .completed)
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
        case "credentials", "auth":
            markProgressCompleted("docs")
            setProgressStep("credentials", status: .failed)
        case "factory", "build":
            markProgressCompleted("docs")
            markProgressCompleted("credentials")
            setProgressStep("factory", status: .failed)
        case "review":
            markProgressCompleted("docs")
            markProgressCompleted("credentials")
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
                markProgressCompleted("credentials")
                markProgressActive("factory")
            case "complete":
                markProgressCompleted("docs")
                markProgressCompleted("credentials")
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
                markProgressCompleted("credentials")
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
        reservedPluginID = nil
        guard let vendor = skillDraft.inferredConnectorVendor else {
            phase = .failed(step: .skill, message: "Could not determine which messaging service this plugin targets.")
            return
        }
        let sessionID = creationSessionID
        let apiKey = creationAPIKey
        let reviewerJSON = creationReviewerModelJSON
        discoverTask = Task { @MainActor in
            let review = await PluginCreatorAccessDocsReview.discover(
                vendor: vendor,
                sourceName: vendor.displayName,
                documentationURL: nil,
                sessionID: sessionID,
                apiKey: apiKey,
                reviewerModelJSON: reviewerJSON,
                onProgress: { [weak self] message in
                    Task { @MainActor in
                        self?.statusMessage = message
                    }
                }
            )
            guard !Task.isCancelled else { return }
            if let failure = review.failure {
                phase = .failed(
                    step: .credentials,
                    message: PluginAccessAskPolicy.docsURLQuestion(
                        triedURL: review.documentationURL,
                        failure: failure
                    )
                )
                return
            }
            pendingAuth = review.auth.preferringCallCredential()
            if phase == .discoveringAuth {
                presentCredentialsOrFail(auth: pendingAuth ?? review.auth)
            }
        }
    }

    private func presentCredentialsOrFail(auth: ConnectorAuthDiscovery) {
        let auth = auth.preferringCallCredential()
        guard auth.authScheme.isSupportedInWizard else {
            phase = .failed(
                step: .credentials,
                message: "OAuth connectors are not available yet. Use a bot token or API key."
            )
            return
        }
        guard let pluginID = reservedPluginID ?? (try? skillDraft.normalizedPluginID()) else {
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
            (
                field.id,
                PluginCredentialFieldCopy.draftValue(
                    hasStoredValue: field.hasStoredValue,
                    developmentValue: PluginSecretDevelopmentSource.resolve(
                        pluginID: pluginID,
                        fieldID: field.id
                    )
                )
            )
        })
        statusMessage = auth.setupHint ?? "Enter the credentials this plugin needs. They are stored in Keychain on your Mac."
        phase = .collectCredentials(pluginID: pluginID)
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
