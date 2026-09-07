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
        case chooseName
        case chooseNews
        case discoveringAuth
        case creating
        case collectCredentials(pluginID: String)
        case failed(step: PluginFactoryCreateInput.FailureStep, message: String, technicalDetail: String? = nil)
        case succeeded(pluginID: String)
        case succeededNews(readerID: String)
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
    @Published var selectedScope: PluginFactoryCreateInput.ConnectorScope = .fullSync
    @Published var customVendorName = ""
    @Published var connectorName = ""
    @Published private(set) var defaultNameReady = false
    @Published var newsName = ""
    @Published var selectedNewsTopics: Set<NewsPresetTopic> = []
    @Published var extraNewsTopics: [String] = []
    @Published var newsTopicDraft = ""
    @Published var selectedNewsSources: Set<NewsPresetSource> = []
    @Published var extraNewsURLs: [String] = []
    @Published var newsURLDraft = ""
    @Published var newsMode: NewsReaderMode = .list
    @Published var newsMaxCount = 20
    @Published var newsSchedule: NewsReaderSchedule = .off
    @Published private(set) var credentialFields: [PluginCredentialFieldPresentation] = []
    @Published var credentialDrafts: [String: String] = [:]

    private var repository: DBRepository?
    private var workflowID: String?
    private var pollAfterSeq = 0
    private var pollTask: Task<Void, Never>?
    private var discoverTask: Task<Void, Never>?
    private var namePrepareTask: Task<Void, Never>?
    private var generatedConnectorName = ""
    private var pendingAuth: ConnectorAuthDiscovery?
    private var creationAPIKey: String?
    private var creationReviewerModelJSON: String?
    private var creationSessionID = ""

    deinit {
        pollTask?.cancel()
        discoverTask?.cancel()
        namePrepareTask?.cancel()
    }

    var canConfirmName: Bool {
        guard defaultNameReady else { return false }
        let trimmed = connectorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return (try? PluginID.normalized(trimmed)) != nil
    }

    var canConfirmVendor: Bool {
        guard selectedVendor.isSelectableInWizard else { return false }
        if selectedVendor == .custom {
            return !customVendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var canConfirmNews: Bool {
        let nameOK = !newsName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return nameOK && !builtNewsSources().isEmpty
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

    func showIntro() {
        cancelPolling()
        discoverTask?.cancel()
        namePrepareTask?.cancel()
        pendingAuth = nil
        phase = .intro
        statusMessage = ""
        progressSteps = []
        credentialFields = []
        credentialDrafts = [:]
        selectedScope = .fullSync
        connectorName = ""
        generatedConnectorName = ""
        defaultNameReady = false
    }

    func beginCreate() {
        cancelPolling()
        phase = .chooseType
        statusMessage = ""
        progressSteps = []
    }

    func selectType(_ type: PluginFactoryCreateInput.PluginType) {
        selectedType = type
    }

    func confirmTypeSelection() {
        if selectedType == .newsReader {
            resetNewsDraft()
            phase = .chooseNews
            return
        }
        guard selectedType == .connector else {
            phase = .failed(
                step: .type,
                message: "Custom plugins are not available yet."
            )
            return
        }
        selectedVendor = .slack
        refreshDefaultConnectorName()
        phase = .chooseVendor
    }

    func confirmVendor(
        sessionID: String,
        helperAPIKey: String?,
        helperReviewerModelJSON: String?
    ) {
        selectedScope = .fullSync
        creationSessionID = sessionID
        creationAPIKey = helperAPIKey
        creationReviewerModelJSON = helperReviewerModelJSON
        defaultNameReady = false
        phase = .chooseName
        namePrepareTask?.cancel()
        namePrepareTask = Task { @MainActor in
            await PluginFactoryListStore.shared.reload()
            guard !Task.isCancelled else { return }
            refreshDefaultConnectorName()
            defaultNameReady = true
            startAuthDiscovery()
        }
    }

    func confirmConnectorName() {
        guard canConfirmName else { return }
        if let pendingAuth {
            presentCredentialsOrFail(auth: pendingAuth)
        } else {
            phase = .discoveringAuth
            statusMessage = "Reading how this service authenticates…"
        }
    }

    func goBackToTypeSelection() {
        namePrepareTask?.cancel()
        discoverTask?.cancel()
        pendingAuth = nil
        defaultNameReady = false
        phase = .chooseType
    }

    func goBackToVendor() {
        namePrepareTask?.cancel()
        discoverTask?.cancel()
        pendingAuth = nil
        defaultNameReady = false
        phase = .chooseVendor
    }

    func addNewsTopic() {
        let topic = newsTopicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }
        if !extraNewsTopics.contains(where: { $0.compare(topic, options: .caseInsensitive) == .orderedSame }) {
            extraNewsTopics.append(topic)
        }
        newsTopicDraft = ""
    }

    func removeNewsTopic(_ topic: String) {
        extraNewsTopics.removeAll { $0 == topic }
    }

    func addNewsURL() {
        let url = newsURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        extraNewsURLs.append(url)
        newsURLDraft = ""
    }

    func removeNewsURL(_ url: String) {
        extraNewsURLs.removeAll { $0 == url }
    }

    func startNewsCreation() {
        let spec = NewsReaderSpec(
            name: newsName,
            topics: builtNewsTopics(),
            sources: builtNewsSources(),
            mode: newsMode,
            maxCount: newsMaxCount,
            schedule: newsSchedule
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
        statusMessage = "Checking sources…"
        progressSteps = [
            ProgressStepState(id: "sources", title: "Check sources for paywalls", status: .active),
            ProgressStepState(id: "fetch", title: "Fetch articles with source links", status: .pending),
        ]
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            do {
                let saved = try await NewsReaderStore.shared.create(spec)
                setProgressStep("sources", status: .completed)
                setProgressStep("fetch", status: .completed)
                phase = .succeededNews(readerID: saved.id)
            } catch let error as NewsReaderError {
                setProgressStep("sources", status: .failed)
                phase = .failed(
                    step: .news,
                    message: error.localizedDescription,
                    technicalDetail: String(describing: error)
                )
            } catch {
                setProgressStep("sources", status: .failed)
                phase = .failed(
                    step: .news,
                    message: error.localizedDescription
                )
            }
        }
    }

    func builtNewsTopics() -> [String] {
        selectedNewsTopics.map(\.displayName) + extraNewsTopics
    }

    func builtNewsSources() -> [NewsSource] {
        var sources = selectedNewsSources.map(\.source)
        for raw in extraNewsURLs + [newsURLDraft] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = NewsSourceURL.canonicalFetchURL(
                URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
                    ?? URL(string: "https://news.google.com/rss")!
            ).absoluteString
            sources.append(NewsSource(label: hostLabel(normalized), url: normalized))
        }
        var seen = Set<String>()
        return sources.filter { seen.insert($0.url).inserted }
    }

    private func resetNewsDraft() {
        newsName = ""
        selectedNewsTopics = []
        extraNewsTopics = []
        newsTopicDraft = ""
        selectedNewsSources = []
        extraNewsURLs = []
        newsURLDraft = ""
        newsMode = .list
        newsMaxCount = 20
        newsSchedule = .off
    }

    private func hostLabel(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    func startCreation(
        sessionID: String,
        helperAPIKey: String?,
        helperReviewerModelJSON: String?
    ) {
        guard selectedVendor.isSelectableInWizard else {
            phase = .failed(
                step: .vendor,
                message: "Only Slack connectors can be created right now."
            )
            return
        }
        guard let helperAPIKey, !helperAPIKey.isEmpty else {
            phase = .failed(
                step: .vendor,
                message: "Add an API key in Settings before creating a plugin."
            )
            return
        }
        guard let pluginID = normalizedConnectorName(),
              let auth = pendingAuth
        else {
            phase = .failed(
                step: .name,
                message: "Name this connector and save its credentials before creating it."
            )
            return
        }
        guard auth.authScheme.isSupportedInWizard else {
            phase = .failed(
                step: .auth,
                message: "OAuth connectors are not available yet. Use a bot token or API key."
            )
            return
        }

        selectedScope = .fullSync
        cancelPolling()
        phase = .creating
        statusMessage = "Starting connector creation…"
        resetProgressSteps()
        pollAfterSeq = 0

        let input = PluginFactoryCreateInput.makeConnector(
            vendor: selectedVendor,
            pluginID: pluginID,
            auth: auth,
            customVendorName: selectedVendor == .custom ? customVendorName : nil,
            scope: selectedScope,
            userDescription: ""
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
            try ConnectorCredentialSaver.persistRequired(
                pluginID: pluginID,
                fields: credentialFields,
                drafts: credentialDrafts
            )
            markProgressCompleted("credentials")
            startCreation(
                sessionID: creationSessionID,
                helperAPIKey: creationAPIKey,
                helperReviewerModelJSON: creationReviewerModelJSON
            )
        } catch {
            phase = .failed(
                step: .auth,
                message: "Could not save credentials: \(error.localizedDescription)"
            )
        }
    }

    func retryFromFailure() {
        switch phase {
        case .failed(let step, _, _):
            switch step {
            case .type: phase = .chooseType
            case .news: phase = .chooseNews
            case .name: phase = .chooseName
            case .auth: phase = .chooseName
            case .vendor, .description, .creating:
                selectedVendor = .slack
                phase = .chooseVendor
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
                    await PluginFactoryListStore.shared.reload()
                    if let pluginID = parseSuccessPluginID(result.resultJSON) {
                        markProgressCompleted("credentials")
                        phase = .succeeded(pluginID: pluginID)
                    } else {
                        if let saved = PluginFactoryListStore.shared.releases.first {
                            markProgressCompleted("credentials")
                            phase = .succeeded(pluginID: saved.pluginID)
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

    private func parseSuccessPluginID(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let result = try? JSONDecoder.service.decode(PluginFactoryCreateResult.self, from: data)
        else {
            return nil
        }
        return result.pluginID
    }

    private func refreshDefaultConnectorName() {
        let existing = PluginFactoryListStore.shared.pluginIDs
        let generated = ConnectorPluginNaming.defaultPluginID(
            vendor: selectedVendor,
            existingIDs: existing
        )
        if connectorName.isEmpty
            || ConnectorPluginNaming.isGeneratedDefault(pluginID: connectorName, vendor: selectedVendor)
            || connectorName == generatedConnectorName {
            connectorName = generated
        }
        generatedConnectorName = generated
    }

    private func normalizedConnectorName() -> String? {
        let trimmed = connectorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? PluginID.normalized(trimmed).rawValue
    }

    private func startAuthDiscovery() {
        discoverTask?.cancel()
        pendingAuth = nil
        let vendor = selectedVendor
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
                step: .auth,
                message: "OAuth connectors are not available yet. Use a bot token or API key."
            )
            return
        }
        guard let pluginID = normalizedConnectorName() else {
            phase = .chooseName
            return
        }
        let descriptors = auth.secrets.map(\.descriptor)
        guard !descriptors.isEmpty else {
            phase = .failed(
                step: .auth,
                message: "Could not determine which credentials this connector needs."
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
        statusMessage = auth.setupHint ?? "Enter the credentials this connector needs. They are stored in Keychain on your Mac."
        phase = .collectCredentials(pluginID: pluginID)
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
