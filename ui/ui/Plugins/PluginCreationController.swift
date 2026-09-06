import Combine
import DBRepository
import Foundation
import Structure

@MainActor
final class PluginCreationController: ObservableObject {
    enum Phase: Equatable {
        case intro
        case chooseType
        case chooseVendor
        case describe
        case creating
        case collectCredentials(pluginID: String)
        case failed(step: PluginFactoryCreateInput.FailureStep, message: String, technicalDetail: String? = nil)
        case succeeded(pluginID: String)
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
    @Published var selectedType: PluginFactoryCreateInput.PluginType = .connector
    @Published var selectedVendor: PluginFactoryCreateInput.ConnectorVendor = .slack
    @Published var selectedScope: PluginFactoryCreateInput.ConnectorScope = .sendAndReceive
    @Published var customVendorName = ""
    @Published var connectorDescription = ""
    @Published private(set) var credentialFields: [PluginCredentialFieldPresentation] = []
    @Published var credentialDrafts: [String: String] = [:]

    private var repository: DBRepository?
    private var workflowID: String?
    private var pollAfterSeq = 0
    private var pollTask: Task<Void, Never>?

    deinit {
        pollTask?.cancel()
    }

    func configure(repository: DBRepository) {
        self.repository = repository
    }

    var canSaveCredentials: Bool {
        ConnectorCredentialSaver.canSave(
            fields: credentialFields,
            drafts: credentialDrafts,
            mode: .requireMissing
        )
    }

    func showIntro() {
        cancelPolling()
        phase = .intro
        statusMessage = ""
        progressSteps = []
        credentialFields = []
        credentialDrafts = [:]
        selectedScope = .sendAndReceive
    }

    func beginCreate() {
        cancelPolling()
        phase = .chooseType
        statusMessage = ""
        progressSteps = []
    }

    func beginEdit() {
        phase = .failed(
            step: .type,
            message: "Editing an existing plugin is coming soon. Delete a version from the sidebar and create a new one."
        )
    }

    func selectType(_ type: PluginFactoryCreateInput.PluginType) {
        selectedType = type
    }

    func confirmTypeSelection() {
        guard selectedType == .connector else {
            phase = .failed(
                step: .type,
                message: "Only connector plugins are supported today. News reader and custom types are coming soon."
            )
            return
        }
        phase = .chooseVendor
    }

    func confirmVendor() {
        selectedScope = .sendAndReceive
        phase = .describe
    }

    func goBackToTypeSelection() {
        phase = .chooseType
    }

    func goBackToVendorSelection() {
        phase = .chooseVendor
    }

    func startCreation(
        sessionID: String,
        helperAPIKey: String?,
        helperReviewerModelJSON: String?
    ) {
        guard let helperAPIKey, !helperAPIKey.isEmpty else {
            phase = .failed(
                step: .description,
                message: "Add an API key in Settings before creating a plugin."
            )
            return
        }

        selectedScope = .sendAndReceive
        cancelPolling()
        phase = .creating
        statusMessage = "Starting connector creation…"
        resetProgressSteps()
        pollAfterSeq = 0

        let input = PluginFactoryCreateInput.makeConnector(
            vendor: selectedVendor,
            customVendorName: selectedVendor == .custom ? customVendorName : nil,
            scope: selectedScope,
            userDescription: connectorDescription
        )

        pollTask = Task { @MainActor in
            do {
                let inputJSON = try input.encodedJSON()
                let handle = try await WorkflowRuntimeClient.shared.startWorkflow(
                    WorkflowStartRequest(
                        kind: .pluginFactoryCreate,
                        sessionID: sessionID,
                        agentID: "ui",
                        inputJSON: inputJSON,
                        principal: .agent(sessionID: sessionID, agentID: "ui"),
                        helperAPIKey: helperAPIKey,
                        helperReviewerModelJSON: helperReviewerModelJSON
                    )
                )
                workflowID = handle.workflowID
                await pollUntilTerminal()
            } catch {
                phase = .failed(step: .creating, message: error.localizedDescription)
            }
        }
    }

    func saveCredentialsAndFinish() {
        guard case .collectCredentials(let pluginID) = phase else { return }
        do {
            try ConnectorCredentialSaver.savePartial(
                pluginID: pluginID,
                fields: credentialFields,
                drafts: credentialDrafts
            )
            setProgressStep("credentials", status: .completed)
            phase = .succeeded(pluginID: pluginID)
        } catch {
            phase = .failed(
                step: .creating,
                message: "Could not save credentials: \(error.localizedDescription)"
            )
        }
    }

    func retryFromFailure() {
        switch phase {
        case .failed(let step, _, _):
            switch step {
            case .type: phase = .chooseType
            case .vendor: phase = .chooseVendor
            case .description: phase = .describe
            case .creating: phase = .describe
            }
        default:
            phase = .intro
        }
    }

    func dismissSuccess() {
        showIntro()
    }

    private func resetProgressSteps() {
        progressSteps = [
            ProgressStepState(id: "docs", title: "Read vendor API docs", status: .pending),
            ProgressStepState(id: "factory", title: "Build and test plugin", status: .pending),
            ProgressStepState(id: "review", title: "Safety review", status: .pending),
            ProgressStepState(id: "credentials", title: "Save credentials to Keychain", status: .pending),
        ]
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
        case "factory", "build", "review":
            markProgressCompleted("docs")
            setProgressStep("factory", status: .failed)
            setProgressStep("review", status: .failed)
        default:
            if progressSteps.first(where: { $0.id == "docs" })?.status == .completed {
                setProgressStep("factory", status: .failed)
            } else {
                setProgressStep("docs", status: .failed)
            }
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
            }
            if message.contains("review decision=rejected") || message.contains("review rejected=") {
                markProgressCompleted("factory")
                markProgressActive("review")
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
                    if event.kind == "progress",
                       WorkflowChatProgress.shouldSurfaceWorkflowMessage(event.message) {
                        statusMessage = event.message
                    } else if let mapped = WorkflowChatProgress.factoryProgressMessage(from: event.message) {
                        statusMessage = mapped
                    }
                }
                switch result.status {
                case .completed:
                    markProgressCompleted("docs")
                    markProgressCompleted("factory")
                    markProgressCompleted("review")
                    if let pluginID = parseSuccessPluginID(result.resultJSON) {
                        await prepareCredentialsPhase(pluginID: pluginID)
                    } else {
                        await PluginFactoryListStore.shared.reload()
                        if let saved = PluginFactoryListStore.shared.releases.first {
                            await prepareCredentialsPhase(pluginID: saved.pluginID)
                        } else {
                            phase = .failed(
                                step: .creating,
                                message: """
                                The connector was not saved. Creation reported success but no plugin release was found.
                                """,
                                technicalDetail: result.resultJSON
                            )
                        }
                    }
                    cancelPolling()
                    return
                case .failed:
                    let stage = result.events.last(where: { $0.kind == "log" })?.stage
                    markProgressFailed(fromStage: stage)
                    let raw = result.errorMessage ?? "Connector creation failed."
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
                        step: .creating,
                        message: "The connector was not saved. Creation was cancelled before it finished."
                    )
                    cancelPolling()
                    return
                case .running:
                    break
                }
            } catch {
                phase = .failed(step: .creating, message: error.localizedDescription)
                cancelPolling()
                return
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    private func prepareCredentialsPhase(pluginID: String) async {
        guard let repository else {
            phase = .succeeded(pluginID: pluginID)
            return
        }
        await PluginFactoryListStore.shared.reload()
        let descriptors = await ConnectorCredentialService.secretDescriptors(
            pluginID: pluginID,
            repository: repository
        )
        guard !descriptors.isEmpty else {
            phase = .succeeded(pluginID: pluginID)
            return
        }
        let fields = PluginCredentialFieldPresentation.presentations(
            for: descriptors,
            pluginID: pluginID
        )
        if fields.allSatisfy(\.hasStoredValue) {
            markProgressCompleted("credentials")
            phase = .succeeded(pluginID: pluginID)
            return
        }
        credentialFields = fields
        credentialDrafts = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, "") })
        markProgressActive("credentials")
        statusMessage = "Enter the credentials this connector needs. They are stored in Keychain on your Mac."
        phase = .collectCredentials(pluginID: pluginID)
    }

    private func parseSuccessPluginID(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let result = try? JSONDecoder.service.decode(PluginFactoryCreateResult.self, from: data)
        else {
            return nil
        }
        return result.pluginID
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
