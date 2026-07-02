import AppKit
import LLMAgentClient
import SwiftUI

struct ChatTurn: Identifiable, Hashable {
    let id = UUID()
    let prompt: String
    var response: String
}

private enum MarkdownBlock: Identifiable {
    case paragraph(String)
    case code(language: String?, code: String)

    var id: String {
        switch self {
        case .paragraph(let text):
            return "p-\(text.hashValue)"
        case .code(let language, let code):
            return "c-\(language ?? "")-\(code.hashValue)"
        }
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCodeBlock = false

        func flushParagraph() {
            let paragraph = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = nil
                    inCodeBlock = false
                } else {
                    flushParagraph()
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : String(language)
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraphLines.append(line)
            }
        }

        if inCodeBlock {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        } else {
            flushParagraph()
        }

        return blocks.isEmpty ? [.paragraph(text)] : blocks
    }
}

private struct MarkdownResponseView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlock.parse(text)

        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                blockView(for: block)
            }
        }
    }

    @ViewBuilder
    private func blockView(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(attributedMarkdown(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal) {
                    Text(verbatim: code)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func attributedMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private struct PromptInputView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.string = text
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PromptTextView else {
            return
        }

        textView.onSubmit = onSubmit

        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text = textView.string
        }
    }
}

private final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.option, .shift]).isEmpty {
            onSubmit?()
            return
        }

        super.keyDown(with: event)
    }
}

struct ContentView: View {
    private let modelIdentifier = "gemini-3.1-flash-lite"
    private let geminiKeychainAccount = "gemini-api-key"
    private let secretResolver = AppSecretResolver()
    private let isDebugEnabled = ProcessInfo.processInfo.environment["DEBUG_ENABLED"]?.lowercased() == "true"
    @ObservedObject private var debugLogStore = DebugLogStore.shared

    private var secretStore: SecretStore {
        SecretStore(account: geminiKeychainAccount)
    }

    @State private var conversation: ConversationModel?
    @State private var prompt = "Write a short haiku about layered architecture."
    @State private var turns: [ChatTurn] = []
    @State private var isStreaming = false
    @State private var errorMessage: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var isPresentingAPIKeyPrompt = false
    @State private var apiKeyDraft = ""
    @State private var shouldResumeAfterSavingKey = false

    private var canSendPrompt: Bool {
        conversation != nil
            && !isStreaming
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gemini Stream")
                .font(.largeTitle.bold())

            Text("Send a prompt to `\(modelIdentifier)` and stream the response live.")
                .foregroundStyle(.secondary)

            if conversation == nil {
                ProgressView("Loading session store...")
            }

            PromptInputView(text: $prompt) {
                guard canSendPrompt else {
                    return
                }

                startStreaming()
            }
            .frame(minHeight: 90)
            .disabled(conversation == nil || isStreaming)

            HStack {
                Button(isStreaming ? "Streaming..." : "Send") {
                    startStreaming()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSendPrompt)

                Button("Clear") {
                    turns.removeAll()
                    errorMessage = nil
                }
                .disabled(isStreaming)

                if isStreaming {
                    Button("Cancel") {
                        requestTask?.cancel()
                        requestTask = nil
                        isStreaming = false
                    }
                }

                Spacer()
            }

            if isDebugEnabled {
                debugPanel
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 12) {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Copy") {
                        copyToPasteboard(errorMessage)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Prompt")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button("Copy All") {
                                    copyTurn(turn)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Text(turn.prompt)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)

                            Divider()

                            Text("Response")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if turn.response.isEmpty && isStreaming {
                                Text("Streaming...")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(.secondary)
                            } else {
                                MarkdownResponseView(text: turn.response)
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .frame(minHeight: 320)
        }
        .padding(24)
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

    private var debugPanel: some View {
        let databaseURL = conversation?.databaseDirectoryURL.appendingPathComponent("derrick.sqlite3")
        let fileExists = databaseURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) * 0.4

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Debug")
                    .font(.headline)

                Spacer()

                Text("DEBUG_ENABLED")
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
                            HStack(alignment: .top, spacing: 10) {
                                Text(debugLogStore.formattedTimestamp(for: entry))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var apiKeyPrompt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter API Key")
                .font(.title2.bold())

            Text("Store the Gemini API key in Keychain. This stays on your machine and is not bundled into the app.")
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
            errorMessage = "API key is missing. Enter it for Gemini."
            shouldResumeAfterSavingKey = true
            apiKeyDraft = ""
            isPresentingAPIKeyPrompt = true
            return
        }

        requestTask?.cancel()
        errorMessage = nil
        isStreaming = true

        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        turns.append(ChatTurn(prompt: promptText, response: ""))

        let turnIndex = turns.count - 1

        requestTask = Task {
            do {
                let stream = await conversation.stream(prompt: promptText, apiKey: apiKey)
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
            account: geminiKeychainAccount,
            environmentKeys: [apiKeyEnvironmentKey, legacyAPIKeyEnvironmentKey]
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

    private var apiKeyEnvironmentKey: String {
        modelIdentifier
            .replacingOccurrences(of: "-", with: "_")
            .uppercased()
            + "_API_KEY"
    }

    private var legacyAPIKeyEnvironmentKey: String {
        "GEMINI_API_KEY"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview {
    ContentView()
}
