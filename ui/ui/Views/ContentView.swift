import AppKit
import LLMAgentClient
import SwiftUI

private let bottomPromptFontSize = CGFloat(11)
private let bottomPromptIconSize = CGFloat(10)

struct ChatTurn: Identifiable, Hashable {
    let id = UUID()
    let prompt: String
    var response: String
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
        SecretStore(account: selectedProvider.keychainAccount)
    }

    @State private var conversation: ConversationModel?
    @State private var prompt = ""
    @State private var turns: [ChatTurn] = []
    @State private var isStreaming = false
    @State private var errorMessage: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var isPresentingAPIKeyPrompt = false
    @State private var apiKeyDraft = ""
    @State private var shouldResumeAfterSavingKey = false
    @State private var selectedProvider: LLMProviderChoice = .gemini
    @State private var selectedModel: LLMModelChoice = .gemini(.gemini31FlashLite)

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
            SidebarView()
                .frame(width: 296)
                .background(Color(red: 248.0/255.0, green: 248.0/255.0, blue: 246.0/255.0))

            mainPanel
        }
        .sheet(isPresented: $isPresentingAPIKeyPrompt) {
            apiKeyPrompt
        }
        .task {
            if isDebugEnabled {
                await MainActor.run {
                    debugLogStore.log("Loading session store")
                }
            }

            if conversation == nil {
                do {
                    conversation = try await ConversationModel.makeDefault()
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

                    panelContent(inputHeight: inputHeight)
                }
            }
    }

    private func panelContent(inputHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if turns.isEmpty {
                Spacer()

                emptyState
                    .padding(.bottom, 28)

                composer(inputHeight: inputHeight)
                    .frame(maxWidth: 700)
                    .padding(.horizontal, 24)

                quickActionChips
                    .padding(.top, 18)

                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if conversation == nil {
                            ProgressView("Loading session store...")
                                .padding(.top, 8)
                        }
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(turns) { turn in
                                PromptCompletionCard(turn: turn, isStreaming: isStreaming) {
                                    copyTurn(turn)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                }

                composer(inputHeight: inputHeight)
                    .frame(maxWidth: 700)
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
            Image(systemName: "asterisk")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color(red: 0.796, green: 0.424, blue: 0.298))

            Text("dave returns!")
                .font(.system(size: 36, weight: .regular, design: .serif))
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
            chipButton("lightbulb", label: "Claude's choice")
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

    private func composer(inputHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage {
                errorBanner(message: errorMessage)
                    .padding(.bottom, 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                PromptInputView(text: $prompt) {
                    guard canSendPrompt else { return }
                    startStreaming()
                }
                .frame(height: inputHeight)
                .disabled(conversation == nil || isStreaming)
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
        min(max(availableHeight * 0.13, 130), 320)
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
        let clipboardText = [
            "Prompt:",
            turn.prompt,
            "",
            "Completion:",
            turn.response
        ]
        .joined(separator: "\n")

        copyToPasteboard(clipboardText)
    }

    private var debugLogPanel: some View {
        let databaseURL = conversation?.databaseDirectoryURL.appendingPathComponent("derrick.sqlite3")
        let fileExists = databaseURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) * 0.25

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Debug")
                    .font(.headline)

                Spacer()

                Text("IS_DEBUG=true")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let conversation {
                HStack(spacing: 12) {
                    Text("DB")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(conversation.databaseDirectoryURL.appendingPathComponent("derrick.sqlite3").path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    Text("Exists")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(fileExists ? "yes" : "no")
                        .font(.caption.monospaced())
                }
            } else {
                Text("Session store is loading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(debugLogStore.entries) { entry in
                            HStack(alignment: .bottom, spacing: 10) {
                                Text(debugLogStore.formattedTimestamp(for: entry))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .font(.footnote.monospacedDigit())
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }

                        if debugLogStore.entries.isEmpty {
                            Text("No debug logs yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .onChange(of: debugLogStore.entries.count) { _, _ in
                    guard let lastID = debugLogStore.entries.last?.id else {
                        return
                    }

                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 17))
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var apiKeyPrompt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter API Key")
                .font(.title2.bold())

            Text("Store the \(selectedProvider.displayName) API key in Keychain. This stays on your machine and is not bundled into the app.")
                .foregroundStyle(.secondary)

            SecureField("API Key", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()

                Button("Cancel") {
                    apiKeyDraft = ""
                    shouldResumeAfterSavingKey = false
                    isPresentingAPIKeyPrompt = false
                }

                Button("Save") {
                    saveAPIKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func startStreaming() {
        guard let conversation else {
            errorMessage = "Session store is still loading."
            return
        }

        guard let apiKey = resolveAPIKey() else {
            errorMessage = "API key is missing. Enter it for \(selectedProvider.displayName)."
            shouldResumeAfterSavingKey = true
            apiKeyDraft = ""
            isPresentingAPIKeyPrompt = true
            return
        }

        requestTask?.cancel()
        errorMessage = nil
        isStreaming = true

        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = ""
        turns.append(ChatTurn(prompt: promptText, response: ""))

        let turnIndex = turns.count - 1

        requestTask = Task {
            do {
                let stream = await conversation.stream(prompt: promptText, apiKey: apiKey, model: selectedModel)
                for try await chunk in stream {
                    await MainActor.run {
                        turns[turnIndex].response += chunk
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    if isDebugEnabled {
                        debugLog("Streaming failed: \(error)")
                    }
                }
            }

            await MainActor.run {
                isStreaming = false
                requestTask = nil
            }
        }
    }

    private func resolveAPIKey() -> String? {
        secretResolver.resolve(
            account: selectedProvider.keychainAccount,
            environmentKeys: apiKeyEnvironmentKeys
        )
    }

    private func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        do {
            try secretStore.save(trimmed)
            apiKeyDraft = ""
            isPresentingAPIKeyPrompt = false

            if shouldResumeAfterSavingKey {
                shouldResumeAfterSavingKey = false
                startStreaming()
            }
        } catch {
            errorMessage = error.localizedDescription
            if isDebugEnabled {
                debugLog("API key save failed: \(error)")
            }
        }
    }

    private var apiKeyEnvironmentKeys: [String] {
        selectedProvider.apiKeyEnvironmentKeys
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview {
    ContentView()
}
