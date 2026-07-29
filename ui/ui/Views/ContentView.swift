import AppKit
import Combine
import LLMAgentClient
import SwiftUI
import DBRepository
import PolicyUserInteraction

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
    @State private var conversation: ConversationModel?
    @State private var prompt = "search amazon.com and give me a list of the top 10 bicycles being sold"
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
    @State private var selectedModel: LLMModelChoice = .openai(.gpt5Mini)
    @State private var helperModelSettings: LLMModelSettings?
    @State private var promptFocusToken = 0
    @State private var scrollToBottomToken = 0
    @State private var shouldAutoScroll = true
    @StateObject private var approvalPresentationModel = ApprovalPresentationModel()
    @ObservedObject private var policyEventPresenter = PolicyEventPresenter.shared

    private var canSendPrompt: Bool {
        conversation != nil
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
            minHeight: 160,
            maxWidth: 460,
            maxHeight: 360,
            onBackdropDismiss: {
                if let event = policyEventPresenter.activeEvent,
                   event.kind != .approvalRequired,
                   event.kind != .networkAccessRequest {
                    policyEventPresenter.dismissNotice()
                }
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
            minHeight: 160,
            maxWidth: 440,
            maxHeight: 280,
            onBackdropDismiss: bootstrapStatus.phase == .failed
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
                HStack {
                    Spacer()
                    if bootstrapStatus.phase == .failed {
                        Button("OK") {
                            bootstrapStatus.dismissFailure()
                        }
                        .buttonStyle(ModalPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await MainActor.run {
                policyEventPresenter.start()
                bootstrapStatus.beginLoadingSession()
            }
            if isDebugEnabled {
                await MainActor.run {
                    debugLogStore.log("Loading session store")
                }
            }

            let fallbackDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ui", isDirectory: true)
            let databaseDirectoryURL = (try? AppDatabaseDirectory.resolve(applicationName: "ui")) ?? fallbackDirectoryURL
            
            do {
                let repo = try await ConversationModel.makeMemoryStore(
                    applicationName: "ui",
                    databaseDirectoryURL: databaseDirectoryURL
                )
                repository = repo
                helperModelSettings = LLMModelSettings(repository: repo)
                await helperModelSettings?.loadSettings()
                await EgressAllowlistService.shared.configure(repository: repo)

                conversation = try await ConversationModel.makeDefault(
                    repository: repo,
                    helperModelSettings: helperModelSettings!
                )
                // Helper connection is up via XPCDockerRunner.shared; re-push allowlist.
                await EgressAllowlistService.shared.pushToHelper()
                // XPCDockerRunner starts Docker prewarm; bootstrap modal continues until that finishes.
                await MainActor.run {
                    bootstrapStatus.update(
                        phase: .connectingHelper,
                        message: "Starting Docker environment setup…"
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
                await MainActor.run {
                    debugLog("Session store load failed: \(error)")
                    bootstrapStatus.markFailed(
                        title: "Session Store Failed",
                        message: "Derrick could not open its local database.\n\n\(error.localizedDescription)",
                        technicalDetail: String(describing: error)
                    )
                }
            }

            if isDebugEnabled, conversation != nil {
                await MainActor.run {
                    debugLogStore.log("Session store ready")
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
                            if conversation == nil {
                                ProgressView("Loading session store...")
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
                    .disabled(conversation == nil || isStreaming)
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
        guard let conversation = conversation, !prompt.isEmpty else { return }

        isStreaming = true
        let currentPrompt = prompt
        let currentModel = selectedModel
        prompt = ""
        turns.append(ChatTurn(prompt: currentPrompt, response: ""))
        scrollToBottomToken += 1
        promptFocusToken += 1

        requestTask = Task {
            do {
                let stream = await conversation.stream(
                    prompt: currentPrompt,
                    apiKey: resolveAPIKey() ?? "",
                    model: currentModel,
                    approvalPresenter: approvalPresentationModel
                )
                for try await chunk in stream {
                    if let lastIndex = turns.indices.last {
                        turns[lastIndex].response = turns[lastIndex].response.isEmpty ? chunk.chunk ?? "" : turns[lastIndex].response + (chunk.chunk ?? "")
                        turns[lastIndex].status = chunk.status
                        turns[lastIndex].toolName = chunk.toolName
                        //debugLog("Last turn \(turns[lastIndex])")
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
