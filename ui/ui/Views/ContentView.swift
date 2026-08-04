import AppKit
import AppEvents
import Combine
import LLMAgentClient
import SwiftUI
import DBRepository
import PolicyUserInteraction
import ServiceContracts

private let bottomPromptFontSize = CGFloat(11)
private let bottomPromptIconSize = CGFloat(10)

struct ChatTurn: Identifiable, Hashable {
    let id = UUID()
    let prompt: String
    var response: String
    var status: AgentResponseStatus?
    var toolName: String?
}

private struct SelectableDebugLogView: NSViewRepresentable {
    let text: String

    private func makeAttributedString() -> NSAttributedString {
        let lines = text.components(separatedBy: .newlines)
        var combined = AttributedString()
        
        for (index, line) in lines.enumerated() {
            var lineAttr = (try? AttributedString(markdown: line)) ?? AttributedString(line)
            if index < lines.count - 1 {
                lineAttr.append(AttributedString("\n"))
            }
            combined.append(lineAttr)
        }
        
        combined.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        combined.foregroundColor = Color(NSColor.labelColor)
        return NSAttributedString(combined)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        let nsAttributed = makeAttributedString()
        textView.textStorage?.setAttributedString(nsAttributed)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else {
            return
        }
        
        let nsAttributed = makeAttributedString()
        if textView.attributedString() != nsAttributed {
            textView.textStorage?.setAttributedString(nsAttributed)
        }
    }
}

private final class ScrollObserverToken: @unchecked Sendable {
    private var notificationObserver: NSObjectProtocol?

    func setNotificationObserver(_ observer: NSObjectProtocol?) {
        notificationObserver = observer
    }

    func clear() {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
            self.notificationObserver = nil
        }
    }
}

private struct ScrollViewPositionObserver: NSViewRepresentable {
    let onIsNearBottomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onIsNearBottomChanged: onIsNearBottomChanged)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onIsNearBottomChanged = onIsNearBottomChanged
        DispatchQueue.main.async {
            context.coordinator.attach(from: nsView)
        }
    }

    @MainActor
    final class Coordinator {
        var onIsNearBottomChanged: (Bool) -> Void
        private weak var scrollView: NSScrollView?
        private let observerToken = ScrollObserverToken()
        private var attachAttempts = 0

        init(onIsNearBottomChanged: @escaping (Bool) -> Void) {
            self.onIsNearBottomChanged = onIsNearBottomChanged
        }

        deinit {
            let observerToken = observerToken
            Task { @MainActor in
                observerToken.clear()
            }
        }

        func attach(from view: NSView) {
            guard let scrollView = view.enclosingScrollView else {
                guard attachAttempts < 10 else {
                    return
                }

                attachAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                    guard let self, let view else {
                        return
                    }
                    self.attach(from: view)
                }
                return
            }

            if self.scrollView === scrollView {
                updateScrollState()
                return
            }

            attachAttempts = 0
            observerToken.clear()

            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observerToken.setNotificationObserver(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateScrollState()
                }
            })
            updateScrollState()
        }

        private func updateScrollState() {
            guard let scrollView, let documentView = scrollView.documentView else {
                return
            }

            let visibleRect = scrollView.contentView.documentVisibleRect
            let documentBounds = documentView.bounds
            let distanceFromBottom: CGFloat

            if documentView.isFlipped {
                distanceFromBottom = documentBounds.maxY - visibleRect.maxY
            } else {
                distanceFromBottom = visibleRect.minY - documentBounds.minY
            }

            onIsNearBottomChanged(distanceFromBottom <= 48)
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    @MainActor
    private func configureWindow(for view: NSView) {
        guard let window = view.window else {
            return
        }

        window.appearance = NSAppearance(named: .aqua)

        guard let screen = window.screen ?? NSScreen.main else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let widthScale: CGFloat = 0.725
        let heightScale: CGFloat = 0.75
        let targetFrame = NSRect(
            x: visibleFrame.origin.x + (visibleFrame.width * (1 - widthScale) / 2),
            y: visibleFrame.origin.y + (visibleFrame.height * (1 - heightScale) / 2),
            width: visibleFrame.width * widthScale,
            height: visibleFrame.height * heightScale
        )

        guard !window.frame.equalTo(targetFrame) else {
            return
        }

        window.setFrame(targetFrame, display: true)
    }
}

struct ContentView: View {
    private let secretResolver = AppSecretResolver()
    private let debugConfiguration = AppDebugConfiguration()
    
    @ObservedObject private var debugLogStore = DebugLogStore.shared
    @ObservedObject private var bootstrapStatus = AppBootstrapStatus.shared

    private var secretStore: SecretStore {
        SecretStore(account: "\(selectedProvider.rawValue)-api-key")
    }

    @State private var repository: DBRepository?
    /// UI is a client: chat turns run in AgentService. True after DB + AgentService ensure-up.
    @State private var sessionReady = false
    @State private var prompt = "I need a short practical React guide. Split the research: one worker on hooks pitfalls (useEffect deps, stale closures, rules of hooks), another on component design (composition, controlled vs uncontrolled inputs, list keys, when to split components). Then pull both into one clean write-up with sections for Hooks, Components, and a five-item checklist."
    @State private var turns: [ChatTurn] = []
    @State private var isStreaming = false
    @State private var errorMessage: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var isPresentingAPIKeyPrompt = false
    @State private var isPresentingDockerRequiredAlert = false
    @State private var dockerRequiredMessage = ""
    @State private var apiKeyDraft = ""
    @State private var shouldResumeAfterSavingKey = false
    @State private var selectedProvider: LLMProviderChoice = .openai
    @State private var selectedModel: LLMModelChoice = .openai(.gpt56Luna)
    @State private var helperModelSettings: LLMModelSettings?
    @State private var promptFocusToken = 0
    @State private var scrollToBottomToken = 0
    @State private var shouldAutoScroll = true
    @StateObject private var approvalPresentationModel = ApprovalPresentationModel()
    @ObservedObject private var policyEventPresenter = PolicyEventPresenter.shared

    private var canSendPrompt: Bool {
        sessionReady
            && !isStreaming
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleModels: [LLMModelChoice] {
        selectedProvider.models
    }

    private var isDebugEnabled: Bool {
        debugConfiguration.isDebugEnabled
    }

    var body: some View {
        HStack(spacing: 0) {
            if let helperModelSettings = helperModelSettings {
                SidebarView(helperModelSettings: helperModelSettings)
                    .frame(width: 296)
                    .background(Color(red: 248.0/255.0, green: 248.0/255.0, blue: 246.0/255.0))
            } else {
                Color(red: 248.0/255.0, green: 248.0/255.0, blue: 246.0/255.0)
                    .frame(width: 296)
            }

            mainPanel
        }
        .sheet(isPresented: $isPresentingAPIKeyPrompt) {
            apiKeyPrompt()
        }
        .alert("Docker Desktop required", isPresented: $isPresentingDockerRequiredAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dockerRequiredMessage)
        }
        .modalPopup(
            isPresented: policyEventPresenter.isPresented && !bootstrapStatus.isModalPresented,
            minWidth: 380,
            minHeight: 0,
            maxWidth: 460,
            maxHeight: 360,
            onBackdropDismiss: {
                Self.handlePolicyModalEscape(presenter: policyEventPresenter)
            },
            onEscape: {
                Self.handlePolicyModalEscape(presenter: policyEventPresenter)
            },
            header: {
                if let event = policyEventPresenter.activeEvent {
                    PolicyEventModalHeader(event: event)
                }
            },
            body: {
                if let event = policyEventPresenter.activeEvent {
                    PolicyEventModalBody(event: event)
                }
            },
            footer: {
                if let event = policyEventPresenter.activeEvent {
                    PolicyEventModalFooter(
                        event: event,
                        onDismiss: { policyEventPresenter.dismissNotice() },
                        onApprove: { policyEventPresenter.approve() },
                        onApproveOnce: { policyEventPresenter.approveOnce() },
                        onApproveAlways: { policyEventPresenter.approveAlways() },
                        onDeny: { policyEventPresenter.deny() }
                    )
                }
            }
        )
        .modalPopup(
            isPresented: bootstrapStatus.isModalPresented,
            minWidth: 380,
            minHeight: 0,
            maxWidth: 440,
            maxHeight: 280,
            onBackdropDismiss: bootstrapStatus.phase == .failed
                ? { bootstrapStatus.dismissFailure() }
                : nil,
            onEscape: bootstrapStatus.phase == .failed
                ? { bootstrapStatus.dismissFailure() }
                : nil,
            header: {
                HStack(spacing: 10) {
                    if bootstrapStatus.showsProgressIndicator {
                        ProgressView()
                            .controlSize(.small)
                    } else if bootstrapStatus.phase == .failed {
                        Image(systemName: ModalChrome.bootstrapFailureSymbol)
                            .font(ModalChrome.symbolFont)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(ModalChrome.failureSymbolColor)
                    }
                    Text(bootstrapStatus.phase == .failed
                         ? (bootstrapStatus.failureTitle ?? "Initialization Failed")
                         : "Initializing Derrick")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)
            },
            body: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(bootstrapStatus.statusMessage)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if bootstrapStatus.phase == .failed, let detail = bootstrapStatus.failureMessage,
                       detail != bootstrapStatus.statusMessage {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if bootstrapStatus.isInitializing {
                        Text("This may take a minute the first time while Docker images and containers are prepared.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            },
            footer: {
                // Only show footer chrome when there is an action (avoids empty padded gap while initializing).
                if bootstrapStatus.phase == .failed {
                    HStack {
                        Spacer(minLength: 0)
                        Button("OK") {
                            bootstrapStatus.dismissFailure()
                        }
                        .buttonStyle(ModalPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .padding(.top, 4)
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await MainActor.run {
                policyEventPresenter.start()
                bootstrapStatus.beginLoadingSession()
            }
            // AgentService tool confirms + egress allows route through reverse XPC → UI modals.
            let approvalModel = approvalPresentationModel
            AgentServiceClient.shared.setApprovalHandler { requestDTO in
                let request = ApprovalConfirmationRequest(
                    id: requestDTO.approvalID,
                    sessionID: requestDTO.sessionID,
                    toolName: requestDTO.toolName,
                    argumentsJSON: requestDTO.argumentsJSON,
                    requiredFields: requestDTO.requiredFields
                )
                let decision = await approvalModel.confirm(request)
                switch decision {
                case .approved(let edited, let actor):
                    return AgentApprovalDecisionDTO(
                        approvalID: requestDTO.approvalID,
                        approved: true,
                        editedArgumentsJSON: edited,
                        actor: actor ?? ""
                    )
                case .cancelled(let actor):
                    return AgentApprovalDecisionDTO(
                        approvalID: requestDTO.approvalID,
                        approved: false,
                        editedArgumentsJSON: requestDTO.argumentsJSON,
                        actor: actor ?? ""
                    )
                }
            }
            AgentServiceClient.shared.setNetworkAccessHandler { requestDTO in
                let event = PolicyUserEventFactory.egressAccessRequest(
                    host: requestDTO.host,
                    toolName: requestDTO.toolName
                )
                await MainActor.run {
                    debugLog("[policy-ui] AgentService network access host=\(requestDTO.host)")
                }
                let decision = await AppEventBus.shared.initDecision(event)
                // Apply on the UI process + Docker helper *before* replying so mid-flight
                // CONNECT does not show a second modal after preflight "Always"/"Once".
                await EgressAllowlistService.shared.applyUserNetworkDecision(
                    host: requestDTO.host,
                    decision: decision
                )
                let actor: String
                let decisionCode: String
                switch decision {
                case .approved(let a), .approvedOnce(let a):
                    decisionCode = "once"
                    actor = a ?? ""
                case .approvedPermanently(let a):
                    decisionCode = "always"
                    actor = a ?? ""
                case .denied(let a):
                    decisionCode = "deny"
                    actor = a ?? ""
                case .timedOut:
                    decisionCode = "timeout"
                    actor = "system-timeout"
                case .dismissed:
                    decisionCode = "dismissed"
                    actor = "ui-user"
                }
                return AgentNetworkAccessDecisionDTO(
                    requestID: requestDTO.requestID,
                    decision: decisionCode,
                    actor: actor
                )
            }
            if isDebugEnabled {
                await MainActor.run {
                    debugLogStore.log("Loading session store")
                }
            }

            let fallbackDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ui", isDirectory: true)
            let databaseDirectoryURL = (try? AppDatabaseDirectory.resolve(applicationName: "ui")) ?? fallbackDirectoryURL

            do {
                // UI client bootstrap only: shared DB + settings. No local ConversationModel
                // (turns are hosted entirely in AgentService).
                await MainActor.run {
                    bootstrapStatus.update(phase: .loadingSession, message: "Opening local database…")
                }
                let repo = try await ConversationModel.makeMemoryStore(
                    applicationName: "ui",
                    databaseDirectoryURL: databaseDirectoryURL
                )
                repository = repo
                let settings = LLMModelSettings(repository: repo)
                await settings.loadSettings()
                helperModelSettings = settings
                await EgressAllowlistService.shared.configure(repository: repo)
                await ContentSensitivityGrantService.shared.configure(repository: repo)
                await UsageLimitsService.shared.configure(repository: repo)

                // Parallel: Docker prewarm (required before prompts) + AgentService + MCPService.
                // Modal stays up until Docker finishes; sessionReady only then.
                await MainActor.run {
                    bootstrapStatus.update(phase: .connectingHelper, message: "Starting Docker and services…")
                }
                _ = XPCDockerRunner.shared
                await EgressAllowlistService.shared.pushToHelper()

                async let dockerReady: Void = {
                    try await XPCDockerRunner.shared.waitUntilPrewarmed()
                }()
                async let agentHealth = AgentServiceClient.shared.ensureUpAndHealth()
                async let mcpHealthResult: Result<ServiceHealthReport, Error> = {
                    do {
                        return .success(try await MCPServiceClient.shared.ensureUpAndHealth())
                    } catch {
                        return .failure(error)
                    }
                }()

                // Docker must succeed before prompting is allowed.
                try await dockerReady

                let health = try await agentHealth
                debugLog(
                    "AgentService ensure-up ok status=\(health.status.rawValue) pid=\(health.pid) detail=\(health.detail ?? "")"
                )

                switch await mcpHealthResult {
                case .success(let mcpHealth):
                    debugLog(
                        "MCPService ensure-up ok status=\(mcpHealth.status.rawValue) pid=\(mcpHealth.pid) detail=\(mcpHealth.detail ?? "")"
                    )
                case .failure(let error):
                    debugLog("MCPService ensure-up failed (non-fatal): \(error.localizedDescription)")
                }

                sessionReady = true
                await MainActor.run {
                    bootstrapStatus.markReady()
                }
                if isDebugEnabled {
                    await MainActor.run {
                        debugLogStore.log("UI client ready (Docker prewarm done; AgentService hosts turns)")
                    }
                }
            } catch {
                sessionReady = false
                errorMessage = error.localizedDescription
                await MainActor.run {
                    debugLog("Client bootstrap failed: \(error)")
                    bootstrapStatus.markFailed(
                        title: "Startup Failed",
                        message: "Derrick could not finish client setup.\n\n\(error.localizedDescription)",
                        technicalDetail: String(describing: error)
                    )
                }
            }

            if resolveAPIKey() == nil {
                isPresentingAPIKeyPrompt = true
            }
        }
        .onChange(of: selectedProvider) { _, newProvider in
            if selectedModel.provider != newProvider {
                selectedModel = newProvider.defaultModel
            }
        }
        .onChange(of: selectedModel) { _, newModel in
            if selectedProvider != newModel.provider {
                selectedProvider = newModel.provider
            }
        }
        .background(WindowConfigurator())
    }

    var mainPanel: some View {
        Color(red: 248.0/255.0, green: 248.0/255.0, blue: 246.0/255.0)
            .ignoresSafeArea()
            .overlay {
                GeometryReader { proxy in
                    let inputHeight = promptInputHeight(for: proxy.size.height)
                    let panelWidth = min(max(520, min(proxy.size.width - 48, 805)), 805)

                    panelContent(inputHeight: inputHeight, panelWidth: panelWidth)
                }
            }
    }

    func panelContent(inputHeight: CGFloat, panelWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            if turns.isEmpty {
                Spacer()

                emptyState
                    .padding(.bottom, 28)

                promptComposer(inputHeight: inputHeight)
                    .frame(maxWidth: panelWidth)
                    .padding(.horizontal, 24)

                quickActionChips
                    .padding(.top, 18)

                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !sessionReady {
                                ProgressView("Connecting to AgentService…")
                                    .padding(.top, 8)
                            }
                            
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(turns) { turn in
                                    PromptCompletionCard(
                                        turn: turn,
                                        isStreaming: isStreaming,
                                        isActiveStreamingTurn: isStreaming && turn.id == turns.last?.id,
                                        completionStatus: completionStatus(for: turn),
                                        statusMessage: turn.status?.rawValue,
                                        toolName: turn.toolName
                                    ) {
                                        copyTurn(turn)
                                    }
                                    .transition(.opacity)
                                }
                            }
                            .frame(minWidth: panelWidth, maxWidth: panelWidth)
                            .frame(maxWidth: .infinity, alignment: .center)

                            Color.clear
                                .frame(height: 1)
                                .id("scroll-bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 5)
                        .padding(.bottom, 40)
                        .background(
                            ScrollViewPositionObserver(onIsNearBottomChanged: { isNearBottom in
                                shouldAutoScroll = isNearBottom
                            })
                        )
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                    .onAppear {
                        shouldAutoScroll = true
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: scrollToBottomToken) { _, _ in
                        if shouldAutoScroll {
                            scrollToBottom(proxy)
                        }
                    }
                }

                promptComposer(inputHeight: inputHeight)
                    .frame(maxWidth: panelWidth)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }

            if isDebugEnabled {
                debugLogPanel
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
    }

    private var emptyState: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("dave returns!")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(nsColor: .labelColor))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var quickActionChips: some View {
        HStack(spacing: 10) {
            chipButton("pencil", label: "Write")
            chipButton("book.closed", label: "Learn")
            chipButton("chevron.left.forwardslash.chevron.right", label: "Code")
            chipButton("cup.and.saucer", label: "Life stuff")
            chipButton("lightbulb", label: "Derrick's choice")
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func chipButton(_ icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(label)
                .font(.system(size: 12))
        }
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.clear)
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func promptComposer(inputHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage {
                errorBanner(message: errorMessage)
                    .padding(.bottom, 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    PromptInputView(text: $prompt, onSubmit: {
                        guard canSendPrompt else { return }
                        startStreaming()
                    }, focusToken: promptFocusToken)
                    .frame(height: inputHeight)
                    .disabled(!sessionReady || isStreaming)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

                Divider()

                HStack(spacing: 12) {
                    Button {
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: bottomPromptFontSize, weight: .regular))
                            .foregroundStyle(Color(nsColor: .labelColor))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Menu {
                        Picker("Provider", selection: $selectedProvider) {
                            ForEach(LLMProviderChoice.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: bottomPromptIconSize, weight: .medium))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            Text(selectedProvider.displayName)
                                .font(.system(size: bottomPromptFontSize))
                                .foregroundStyle(Color(nsColor: .labelColor))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(isStreaming)

                    Menu {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(visibleModels) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: bottomPromptIconSize, weight: .medium))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            Text(selectedModel.displayName)
                                .font(.system(size: bottomPromptFontSize))
                                .foregroundStyle(Color(nsColor: .labelColor))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(isStreaming)

                    Button {
                        startStreaming()
                    } label: {
                        Image(systemName: isStreaming ? "stop.circle.fill" : "mic")
                            .font(.system(size: bottomPromptFontSize))
                            .foregroundStyle(
                                isStreaming
                                    ? Color.red
                                    : Color(nsColor: .labelColor)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSendPrompt && !isStreaming)

                    Button {
                        if isStreaming {
                            requestTask?.cancel()
                            requestTask = nil
                            isStreaming = false
                        } else {
                            turns.removeAll()
                            errorMessage = nil
                        }
                    } label: {
                        Image(systemName: turns.isEmpty && !isStreaming ? "waveform" : "trash")
                            .font(.system(size: bottomPromptFontSize))
                            .foregroundStyle(Color(nsColor: turns.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(turns.isEmpty && !isStreaming)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        }
    }

    private func promptInputHeight(for availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.10, 100), 300)
    }

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Copy") {
                copyToPasteboard(message)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func copyTurn(_ turn: ChatTurn) {
        let completion = turn.response.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = completion.isEmpty ? turn.prompt : completion
        copyToPasteboard(text)
    }

    private var debugLogPanel: some View {
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) * 0.25

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Debug").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Copy Log") {
                    copyToPasteboard(debugLogStore.entries.map { "[\(debugLogStore.formattedTimestamp(for: $0))] \($0.message)" }.joined(separator: "\n"))
                }
            }
            SelectableDebugLogView(text: debugLogStore.entries.map { "[\(debugLogStore.formattedTimestamp(for: $0))] \($0.message)" }.joined(separator: "\n"))
                .frame(maxHeight: maxHeight)
        }
        .padding(16)
        .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func completionStatus(for turn: ChatTurn) -> PromptCompletionCard.CompletionStatus {
        switch turn.status {
        case .complete:
            return .completed
        default:
            return .streaming
        }
    }

    private func startStreaming() {
        guard sessionReady, !prompt.isEmpty else { return }

        isStreaming = true
        let currentPrompt = prompt
        let currentModel = selectedModel
        prompt = ""
        turns.append(ChatTurn(prompt: currentPrompt, response: ""))
        scrollToBottomToken += 1
        promptFocusToken += 1

        requestTask = Task {
            do {
                _ = try await AgentServiceClient.shared.ensureUpAndHealth()
                let modelJSON = try JSONEncoder().encode(currentModel)
                let request = AgentTurnRequest(
                    prompt: currentPrompt,
                    apiKey: resolveAPIKey() ?? "",
                    modelJSON: modelJSON
                )
                let stream = AgentServiceClient.shared.streamTurn(request)
                for try await dto in stream {
                    if let lastIndex = turns.indices.last {
                        let status = AgentResponseStatus(rawValue: dto.status) ?? .thinking
                        turns[lastIndex].response = turns[lastIndex].response.isEmpty
                            ? (dto.chunk ?? "")
                            : turns[lastIndex].response + (dto.chunk ?? "")
                        turns[lastIndex].status = status
                        turns[lastIndex].toolName = dto.toolName
                        scrollToBottomToken += 1
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                let failure = LLMFailureClassifier.classify(error, provider: currentModel.provider)
                LLMFailureReporter.shared.report(failure)
            }
            isStreaming = false
        }
    }

    /// Escape / backdrop: dismiss notices/failures; deny decision-requiring modals.
    private static func handlePolicyModalEscape(presenter: PolicyEventPresenter) {
        guard let event = presenter.activeEvent else { return }
        switch event.kind {
        case .failure, .notice:
            presenter.dismissNotice()
        case .approvalRequired, .networkAccessRequest, .usageLimitRequest:
            presenter.deny()
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo("scroll-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("scroll-bottom", anchor: .bottom)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func resolveAPIKey() -> String? {
        secretResolver.resolve(
            account: selectedModel.provider.secretAccount,
            environmentKeys: selectedModel.provider.apiKeyEnvironmentKeys
        )
    }

    @ViewBuilder
    private func apiKeyPrompt() -> some View {
        VStack(spacing: 20) {
            Text("API Key Required")
                .font(.headline)
            Text("Please enter your \(selectedProvider.apiKeyName) to continue.")
                .font(.subheadline)
            TextField("API Key", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    isPresentingAPIKeyPrompt = false
                }
                Spacer()
                Button("Save") {
                    if let store = try? secretStore {
                        try? store.save(apiKeyDraft)
                        apiKeyDraft = ""
                        isPresentingAPIKeyPrompt = false
                    }
                }
            }
        }
        .padding()
        .frame(width: 300)
    }
}
