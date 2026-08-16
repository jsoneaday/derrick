import AppKit
import AppEvents
import Combine
import LLMAgentClient
import SwiftUI
import DBRepository
import Plugin
import PolicyUserInteraction
import ServiceContracts
private let bottomPromptFontSize = CGFloat(11)
private let bottomPromptIconSize = CGFloat(10)

struct ChatTurn: Identifiable, Hashable {
    let id: UUID
    let prompt: String
    var response: String
    var thought: String
    var status: AgentResponseStatus?
    var toolName: String?
    var pluginTest: PluginInvokePresentation.TestReport?

    init(
        id: UUID = UUID(),
        prompt: String,
        response: String = "",
        thought: String = "",
        status: AgentResponseStatus? = nil,
        toolName: String? = nil,
        pluginTest: PluginInvokePresentation.TestReport? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.response = response
        self.thought = thought
        self.status = status
        self.toolName = toolName
        self.pluginTest = pluginTest
    }

    /// Thinking is the current plan snapshot. Complete appends the user-visible answer.
    mutating func applyStreamChunk(status: AgentResponseStatus, chunk: String) {
        switch status {
        case .thinking:
            thought = chunk
        case .complete:
            if let report = PluginInvokePresentation.decodeTestReport(chunk) {
                pluginTest = report
                response = report.body
                return
            }
            response += chunk
        case .toolCall, .toolBatch:
            break
        }
    }
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

private enum MeshBootstrapError: Error, LocalizedError {
    case step(String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .step(let name, let underlying):
            return "\(name) failed: \(underlying.localizedDescription)"
        }
    }
}

struct ContentView: View {
    private let secretResolver = AppSecretResolver()
    private let debugConfiguration = AppDebugConfiguration()
    
    @ObservedObject private var debugLogStore = DebugLogStore.shared
    @ObservedObject private var bootstrapStatus = AppBootstrapStatus.shared
    @StateObject private var chatSessions = ChatSessionStore()

    private var secretStore: SecretStore {
        SecretStore(account: "\(selectedProvider.rawValue)-api-key")
    }

    @State private var repository: DBRepository?
    /// UI is a client: chat turns run in AgentService. True after DB + AgentService ensure-up.
    @State private var sessionReady = false
    @State private var prompt = "create a plugin that summarizes today's news"
    @State private var errorMessage: String?
    @State private var isPresentingAPIKeyPrompt = false
    @State private var isPresentingDockerRequiredAlert = false
    @State private var dockerRequiredMessage = ""
    @State private var apiKeyDraft = ""
    @State private var shouldResumeAfterSavingKey = false
    @State private var selectedProvider: LLMProviderChoice = .openai
    @State private var selectedModel: LLMModelChoice = .openai(.gpt56Luna)
    @State private var helperModelSettings: LLMModelSettings?
    @State private var promptFocusToken = 0
    @State private var shouldAutoScroll = true
    @State private var isDebugPanelVisible = false
    @ObservedObject private var policyEventPresenter = PolicyEventPresenter.shared
    @ObservedObject private var usageLimitRaisePresenter = UsageLimitRaisePresenter.shared
    @ObservedObject private var pluginList = PluginListStore.shared
    @State private var slashHighlight = 0
    @State private var slashMenuDismissed = false

    private var canSendPrompt: Bool {
        sessionReady
            && !chatSessions.isSelectedTabStreaming
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleModels: [LLMModelChoice] {
        selectedProvider.models
    }

    private var activeTurns: [ChatTurn] {
        chatSessions.selectedTab?.turns ?? []
    }

    private var isActiveTabStreaming: Bool {
        chatSessions.isSelectedTabStreaming
    }

    private var isDebugEnabled: Bool {
        debugConfiguration.isDebugEnabled
    }

    private var slashHandle: String? {
        PluginPrefix.typingHandle(prompt)
    }

    private var slashMatches: [PluginSidebarItem] {
        guard let slashHandle else { return [] }
        return pluginList.slashMatches(handle: slashHandle)
    }

    private var showsSlashMenu: Bool {
        slashHandle != nil && !slashMenuDismissed && sessionReady && !isActiveTabStreaming
    }

    var body: some View {
        HStack(spacing: 0) {
            if let helperModelSettings = helperModelSettings {
                SidebarView(
                    helperModelSettings: helperModelSettings,
                    chatSessions: chatSessions,
                    onInsertPluginPrefix: { prefix in
                        applyPluginPrefix(prefix)
                    }
                )
                    .frame(width: 296)
                    .background(Color(red: 248.0/255.0, green: 248.0/255.0, blue: 246.0/255.0))
            } else {
                Color(red: 248.0/255.0, green: 248.0/255.0, blue: 246.0/255.0)
                    .frame(width: 296)
            }

            VStack(spacing: 0) {
                ChatTabBarView(store: chatSessions)
                mainPanel
            }
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
            isPresented: usageLimitRaisePresenter.isPresented
                && !bootstrapStatus.isModalPresented,
            minWidth: 440,
            minHeight: 0,
            maxWidth: 520,
            maxHeight: 480,
            onBackdropDismiss: { usageLimitRaisePresenter.stop() },
            onEscape: { usageLimitRaisePresenter.stop() },
            header: { EmptyView() },
            body: {
                UsageLimitRaiseModalView(presenter: usageLimitRaisePresenter)
            },
            footer: { EmptyView() }
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
                        Text(
                            bootstrapStatus.phase == .preparingImage
                                ? "First install builds the Bun script image. Keep Docker Desktop running."
                                : "This may take a minute the first time while Docker images and containers are prepared."
                        )
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
            // Single-flight: SwiftUI may re-enter `.task` (sidebar appear / identity churn).
            // A second beginLoadingSession after ready left an undismissable modal and dead UI.
            guard !JobResultPanelSession.isPanelOnlyLaunch,
                  !DerrickNotificationLaunch.hasJobResultPresentationIntent() else {
                fputs("[ui] ContentView bootstrap skipped (panel-only launch)\n", stderr)
                return
            }
            policyEventPresenter.start()
            await bootstrapStatus.runClientBootstrap {
                await self.performClientBootstrap()
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

    /// Full UI client bootstrap (DB, Docker prewarm, Agent/MCP mesh). MainActor for `@State`.
    @MainActor
    private func performClientBootstrap() async {
            guard bootstrapStatus.beginLoadingSession() || bootstrapStatus.isInitializing else {
                if bootstrapStatus.phase == .ready {
                    await syncClientSessionAfterBootstrap()
                }
                return
            }

            // Job wakes persist to DB; results and offline HITL arrive via derrickd notifications.
            HITLLiveApprovalHandlers.wireAgentServiceClient()

            if isDebugEnabled {
                debugLogStore.log("Loading session store")
            }

            do {
                bootstrapStatus.update(phase: .loadingSession, message: "Opening local database…")
                let repo = try await ensureSessionStoreLoaded()
                await EgressAllowlistService.shared.configure(repository: repo)
                await ContentSensitivityGrantService.shared.configure(repository: repo)
                await UsageLimitsService.shared.configure(repository: repo)
                await ContainerLifecycleSettingsService.shared.configure(repository: repo)
                await OrchestrationLimitsSettingsService.shared.configure(repository: repo)
                await SoftwareFactorySettingsService.shared.configure(repository: repo)
                await PluginListStore.shared.configure(repository: repo)
                if isDebugEnabled {
                    await FactoryLogMirror.shared.start(repository: repo)
                }

                bootstrapStatus.update(phase: .connectingHelper, message: "Preparing Derrick daemon…")
                await DaemonBootstrapCoordinator.prepareForHostApp(force: true)

                // Connect derrickd before Docker prewarm so Mach XPC is not competing with
                // long-running DockerRunnerHelper work on the same bootstrap path.
                bootstrapStatus.update(
                    phase: .connectingHelper,
                    message: "Connecting to Derrick daemon…"
                )
                var health = try await AgentServiceClient.shared.ensureUpAndHealth()
                for attempt in 0..<3 {
                    guard await DaemonProcessHygiene.evictIfStaleGuestRuntime(health) else { break }
                    AgentServiceClient.shared.dropConnectionForReconnect()
                    bootstrapStatus.update(
                        phase: .connectingHelper,
                        message: "Restarting background service…"
                    )
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    health = try await AgentServiceClient.shared.ensureUpAndHealth()
                    if attempt == 2, DaemonProcessHygiene.isStaleConnectedDaemon(health) {
                        throw NSError(
                            domain: "DaemonHygiene",
                            code: 409,
                            userInfo: [NSLocalizedDescriptionKey:
                                "Derrick could not replace its background service. Quit Derrick and open it again."]
                        )
                    }
                }
                debugLog(
                    "Daemon ensure-up ok status=\(health.status.rawValue) pid=\(health.pid) runtime=\(health.guestRuntimeImage ?? "?") detail=\(health.detail ?? "")"
                )

                bootstrapStatus.update(phase: .connectingHelper, message: "Starting Docker runtime…")
                _ = XPCDockerRunner.shared

                try await XPCDockerRunner.shared.waitUntilPrewarmed()
                bootstrapStatus.update(phase: .connectingHelper, message: "Finishing setup…")
                await EgressAllowlistService.shared.pushToHelper()

                // Daemon MCP uses its embedded Docker helper; handoff is best-effort while UI is open.
                do {
                    let dockerPeer = try await XPCDockerRunner.shared.fetchPeerListenerEndpoint()
                    try await AgentServiceClient.shared.setDockerHelperPeerEndpoint(dockerPeer)
                    debugLog("Docker helper peer endpoint handed to daemon MCP")
                } catch {
                    debugLog("Docker helper peer handoff skipped: \(error.localizedDescription)")
                }

                sessionReady = true
                bootstrapStatus.markReady()
                await chatSessions.configure(repository: repo)
                await DerrickNotificationService.shared.activateSession(repository: repo)
                await EgressAllowlistService.shared.pushToHelper()
                if isDebugEnabled {
                    debugLogStore.log(
                        "UI client ready (Docker + derrickd Agent/Job/MCP)"
                    )
                }
            } catch is CancellationError {
                if !sessionReady {
                    bootstrapStatus.noteBootstrapCancelled()
                }
                debugLog("Client bootstrap cancelled")
                return
            } catch {
                if sessionReady || bootstrapStatus.phase == .ready {
                    debugLog("Client bootstrap late error ignored (already ready): \(error)")
                } else {
                    sessionReady = false
                    let classified = AppBootstrapStatus.classifyError(error)
                    errorMessage = classified.message
                    debugLog("Client bootstrap failed: \(error)")
                    bootstrapStatus.markFailed(
                        title: classified.title,
                        message: classified.message,
                        technicalDetail: String(describing: error)
                    )
                }
            }

            if resolveAPIKey() == nil {
                isPresentingAPIKeyPrompt = true
            }
    }

    /// Opens the shared DB and model settings when this `ContentView` instance missed the first bootstrap.
    @MainActor
    private func ensureSessionStoreLoaded() async throws -> DBRepository {
        if let repository, let helperModelSettings {
            return repository
        }

        let fallbackDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ui", isDirectory: true)
        let databaseDirectoryURL = (try? AppDatabaseDirectory.resolve(applicationName: "ui")) ?? fallbackDirectoryURL
        let repo = try await ConversationModel.makeMemoryStore(
            applicationName: "ui",
            databaseDirectoryURL: databaseDirectoryURL
        )
        repository = repo
        DerrickNotificationService.shared.configure(repository: repo)
        let settings = LLMModelSettings(repository: repo)
        await settings.loadSettings()
        helperModelSettings = settings
        return repo
    }

    /// Re-attaches local UI state after global bootstrap already reached `.ready`.
    @MainActor
    private func syncClientSessionAfterBootstrap() async {
        guard !sessionReady || helperModelSettings == nil || repository == nil else { return }

        do {
            let repo = try await ensureSessionStoreLoaded()
            sessionReady = true
            await chatSessions.configure(repository: repo)
            await DerrickNotificationService.shared.activateSession(repository: repo)
            if isDebugEnabled {
                debugLogStore.log("UI client session synced after bootstrap ready")
            }
        } catch {
            sessionReady = false
            errorMessage = error.localizedDescription
            debugLog("Client session sync failed: \(error)")
        }
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
        let turns = chatSessions.selectedTab?.turns ?? []
        let isStreaming = chatSessions.isSelectedTabStreaming

        return VStack(spacing: 0) {
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
                    .onChange(of: chatSessions.scrollToBottomToken) { _, _ in
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

            if isDebugEnabled, isDebugPanelVisible {
                debugLogPanel
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isDebugEnabled {
                debugPanelToggle
                    .padding(.trailing, 20)
                    .padding(.bottom, isDebugPanelVisible ? 28 : 16)
            }
        }
    }

    private var debugPanelToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isDebugPanelVisible.toggle()
            }
        } label: {
            Image(systemName: isDebugPanelVisible ? "ladybug.fill" : "ladybug")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.9), in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help(isDebugPanelVisible ? "Hide debug log" : "Show debug log")
        .accessibilityLabel(isDebugPanelVisible ? "Hide debug log" : "Show debug log")
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

            if showsSlashMenu {
                PluginSlashMenu(
                    matches: slashMatches,
                    highlightedIndex: slashHighlight,
                    onChoose: { applySlashCompletion($0) }
                )
                .padding(.bottom, 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    PromptInputView(
                        text: $prompt,
                        onSubmit: {
                            guard canSendPrompt else { return }
                            startStreaming()
                        },
                        focusToken: promptFocusToken,
                        slashKeyHandler: handleSlashKey
                    )
                    .frame(height: inputHeight)
                    .disabled(!sessionReady || isActiveTabStreaming)
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
                    .disabled(isActiveTabStreaming)

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
                    .disabled(isActiveTabStreaming)

                    Button {
                        if isActiveTabStreaming {
                            chatSessions.cancelSelectedTabStream()
                        } else {
                            startStreaming()
                        }
                    } label: {
                        Image(systemName: isActiveTabStreaming ? "stop.circle.fill" : "mic")
                            .font(.system(size: bottomPromptFontSize))
                            .foregroundStyle(
                                isActiveTabStreaming
                                    ? Color.red
                                    : Color(nsColor: .labelColor)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSendPrompt && !isActiveTabStreaming)

                    Button {
                        if isActiveTabStreaming {
                            chatSessions.cancelSelectedTabStream()
                        } else {
                            chatSessions.clearSelectedTabTurns()
                            errorMessage = nil
                        }
                    } label: {
                        Image(systemName: activeTurns.isEmpty && !isActiveTabStreaming ? "waveform" : "trash")
                            .font(.system(size: bottomPromptFontSize))
                            .foregroundStyle(Color(nsColor: activeTurns.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(activeTurns.isEmpty && !isActiveTabStreaming)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        }
        .onChange(of: slashHandle) { _, handle in
            slashHighlight = 0
            slashMenuDismissed = false
            if handle != nil {
                Task { await pluginList.reload() }
            }
        }
        .onChange(of: slashMatches.map(\.id)) { _, _ in
            if slashHighlight >= slashMatches.count {
                slashHighlight = max(slashMatches.count - 1, 0)
            }
        }
    }

    private func handleSlashKey(_ event: NSEvent) -> Bool {
        guard showsSlashMenu else { return false }
        let flags = event.modifierFlags.intersection([.option, .shift, .command, .control])
        switch event.keyCode {
        case 126: // up
            guard !slashMatches.isEmpty else { return true }
            slashHighlight = (slashHighlight + slashMatches.count - 1) % slashMatches.count
            return true
        case 125: // down
            guard !slashMatches.isEmpty else { return true }
            slashHighlight = (slashHighlight + 1) % slashMatches.count
            return true
        case 48: // tab
            guard flags.isEmpty, slashMatches.indices.contains(slashHighlight) else { return false }
            applySlashCompletion(slashMatches[slashHighlight])
            return true
        case 53: // escape
            slashMenuDismissed = true
            return true
        case 36, 76: // return
            guard flags.isEmpty, slashMatches.indices.contains(slashHighlight) else { return false }
            applySlashCompletion(slashMatches[slashHighlight])
            return true
        default:
            return false
        }
    }

    private func applySlashCompletion(_ plugin: PluginSidebarItem) {
        applyPluginPrefix("/\(plugin.id)")
    }

    /// Insert `/plugin-id ` so the operator can add params before sending.
    private func applyPluginPrefix(_ prefix: String) {
        let id = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = id.hasSuffix(" ") ? id : "\(id) "
        slashHighlight = 0
        slashMenuDismissed = true
        promptFocusToken += 1
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

            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
            .help("Dismiss")
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func copyTurn(_ turn: ChatTurn) {
        if let test = turn.pluginTest {
            copyToPasteboard("\(test.heading)\n\(test.body)")
            return
        }
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

        let currentPrompt = prompt
        prompt = ""
        promptFocusToken += 1

        chatSessions.sendPrompt(
            currentPrompt,
            apiKey: resolveAPIKey() ?? "",
            model: selectedModel
        ) { message in
            errorMessage = message
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
