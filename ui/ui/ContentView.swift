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

struct ContentView: View {
    private let modelIdentifier = "gemini-3.1-flash-lite"
    private let geminiKeychainAccount = "gemini-api-key"
    private let secretResolver = AppSecretResolver()

    private var secretStore: SecretStore {
        SecretStore(account: geminiKeychainAccount)
    }

    @State private var conversation = ConversationModel()
    @State private var prompt = "Write a short haiku about layered architecture."
    @State private var turns: [ChatTurn] = []
    @State private var isStreaming = false
    @State private var errorMessage: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var isPresentingAPIKeyPrompt = false
    @State private var apiKeyDraft = ""
    @State private var shouldResumeAfterSavingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gemini Stream")
                .font(.largeTitle.bold())

            Text("Send a prompt to `\(modelIdentifier)` and stream the response live.")
                .foregroundStyle(.secondary)

            TextField("Prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4, reservesSpace: true)

            HStack {
                Button(isStreaming ? "Streaming..." : "Send") {
                    startStreaming()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStreaming || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
                            Text("Prompt")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
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
            if resolveAPIKey() == nil {
                isPresentingAPIKeyPrompt = true
            }
        }
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
