import AppKit
import Combine
import LLMAgentClient
import SwiftUI

private let bottomPromptFontSize = CGFloat(11)
private let bottomPromptIconSize = CGFloat(10)

struct ChatTurn: Identifiable, Hashable {
    let id = UUID()
    let prompt: String
    var response: String
}

private struct SelectableDebugLogView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
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
        textView.string = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              textView.string != text else {
            return
        }
        textView.string = text
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

    private var secretStore: SecretStore {
        SecretStore(account: "\(selectedProvider.rawValue)-api-key")
    }

    @State private var conversation: ConversationModel?
    @State private var prompt = ""
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
    @StateObject private var helperModelSettings = HelperModelSettings()
    @State private var promptFocusToken = 0
    @State private var scrollToBottomToken = 0
    @State private var shouldAutoScroll = true
    @StateObject private var approvalPresentationModel = ApprovalPresentationModel()

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
            SidebarView(helperModelSettings: helperModelSettings)
                .frame(width: 296)
                .background(Color(red: 248.0/255.0, green: 248.0/255.0, blue: 246.0/255.0))

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
        .sheet(item: $approvalPresentationModel.pendingRequest) { request in
            approvalPrompt(request: request)
        }
        .task {
            if isDebugEnabled {
                await MainActor.run {
                    debugLogStore.log("Loading session store")
                }
            }

            if conversation == nil {
                do {
                    conversation = try await ConversationModel.makeDefault(
                        helperModelSettings: helperModelSettings
                    )
                } catch {
                    errorMessage = error.localizedDescription
                    if isDebugEnabled {
                        await MainActor.run {
                            debugLog("Session store load failed: \(error)")
                        }
                    }
                }
            }

            if isDebugEnabled {
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

    private var mainPanel: some View {
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

    private func panelContent(inputHeight: CGFloat, panelWidth: CGFloat) -> some View {
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
                                        statusMessage: debugLogStore.currentStatus
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

    // topBar removed — "Free plan · Upgrade" moved to sidebar footer

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
                    // Attachment button
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

                    // Mic (send) icon
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

                    // Waveform / clear icon
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
        let databaseURL = conversation?.databaseDirectoryURL.appendingPathComponent("derrick.sqlite3")
        let fileExists = databaseURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) * 0.25

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Debug")
                    .font(.system(size: 17, weight: .semibold))

                Spacer()

                Button {
                    copyDebugLogs()
                } label: {
                    Label("Copy logs", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(debugLogStore.entries.isEmpty)

                Text("IS_DEBUG=true")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if let conversation {
                HStack(spacing: 12) {
                    Text("DB")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(conversation.databaseDirectoryURL.appendingPathComponent("derrick.sqlite3").path)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    Text("Exists")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(fileExists ? "yes" : "no")
                        .font(.system(size: 12, design: .monospaced))
                }
            } else {
                Text("Session store is loading.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Divider()

            SelectableDebugLogView(text: formattedDebugLogs)
            .frame(maxHeight: maxHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private func apiKeyPrompt(redacted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(redacted ? "Invalid API Key" : "Enter your API key")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(redacted ? .red : .primary)

            Text("An API key is required to use Derrick. Your key is stored securely in the system keychain.")
                .foregroundStyle(.secondary)

            SecureField(selectedProvider.apiKeyName, text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel", role: .cancel) {
                    apiKeyDraft = ""
                    isPresentingAPIKeyPrompt = false
                }

                Spacer()

                Button("Save") {
                    saveAPIKey(apiKeyDraft)
                    if resolveAPIKey() != nil {
                        apiKeyDraft = ""
                        isPresentingAPIKeyPrompt = false
                        if shouldResumeAfterSavingKey {
                            startStreaming()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func approvalPrompt(request: ApprovalConfirmationRequest) -> some View {
        ApprovalConfirmation(request: request, model: approvalPresentationModel) {
            approvalPresentationModel.cancel()
        } onApprove: {
            approvalPresentationModel.approve()
        }
    }

    private func resolveAPIKey() -> String? {
        let account = "\(selectedProvider.rawValue)-api-key"
        let key = secretResolver.resolve(account: account, environmentKeys: selectedProvider.apiKeyEnvironmentKeys)
        print("API Key resolution: found=\(key != nil)")
        return key
    }

    private func saveAPIKey(_ value: String) {
        do {
            try secretStore.save(value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startStreaming() {
        guard let conversation else {
            return
        }

        if resolveAPIKey() == nil {
            shouldResumeAfterSavingKey = true
            isPresentingAPIKeyPrompt = true
            return
        }

        shouldResumeAfterSavingKey = false

        let capturedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedPrompt.isEmpty else { return }

        errorMessage = nil
        isStreaming = true
        let turn = ChatTurn(prompt: capturedPrompt, response: "")
        turns.append(turn)

        requestTask = Task { @MainActor in
            guard let apiKey = resolveAPIKey() else { return }

            do {
                let stream = await conversation.stream(
                    prompt: capturedPrompt,
                    apiKey: apiKey,
                    model: selectedModel,
                    approvalPresenter: approvalPresentationModel
                )
                
                var accumulated = ""
                for try await chunk in stream {
                    accumulated += chunk
                    if let lastTurn = turns.last, lastTurn.id == turn.id {
                        var current = lastTurn
                        current.response = accumulated
                        turns[turns.count - 1] = current
                        
                        scrollToBottomToken += 1
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                if isDebugEnabled {
                    debugLog("Streaming error: \(error)")
                }
            }
            
            isStreaming = false
            prompt = ""
            scrollToBottomToken += 1
        }
        
        promptFocusToken += 1
        scrollToBottomToken += 1
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.24)) {
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

    private func copyDebugLogs() {
        copyToPasteboard(formattedDebugLogs)
    }

    private var formattedDebugLogs: String {
        debugLogStore.entries.map { entry in
            "\(debugLogStore.formattedTimestamp(for: entry)): \(entry.message)"
        }.joined(separator: "\n")
    }

    private func completionStatus(for turn: ChatTurn) -> PromptCompletionCard.CompletionStatus {
        if let lastTurn = turns.last, lastTurn.id == turn.id {
            if isStreaming {
                return .streaming
            } else if errorMessage != nil {
                return .error
            }
        }
        return .completed
    }
}

#Preview {
    ContentView()
}
