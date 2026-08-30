//
//  PromptView.swift
//  ui
//
//  Derrick
//

import SwiftUI
import LLMAgentClient

private final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var pluginKeyHandler: ((NSEvent) -> Bool)?
    var pluginIDs: [String] = [] {
        didSet { applyPluginHighlighting() }
    }

    override func keyDown(with event: NSEvent) {
        if pluginKeyHandler?(event) == true {
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.option, .shift]).isEmpty {
            onSubmit?()
            return
        }

        super.keyDown(with: event)
    }

    func applyPluginHighlighting() {
        guard let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        guard textStorage.length > 1 else { return }
        let text = string as NSString
        guard text.character(at: 0) == 47 else { return }
        let delimiter = text.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: [],
            range: NSRange(location: 1, length: text.length - 1)
        )
        let tokenLength = delimiter.location == NSNotFound ? text.length : delimiter.location
        guard tokenLength > 1 else { return }
        let token = text.substring(with: NSRange(location: 1, length: tokenLength - 1))
        guard pluginIDs.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame
            || $0.lowercased().hasPrefix(token.lowercased()) }) else {
            return
        }
        textStorage.addAttribute(
            .foregroundColor,
            value: NSColor(calibratedRed: 0.176, green: 0.286, blue: 0.576, alpha: 1),
            range: NSRange(location: 0, length: tokenLength)
        )
    }
}

struct PromptInputView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let focusToken: Int
    var pluginIDs: [String] = []
    var pluginKeyHandler: ((NSEvent) -> Bool)?
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.pluginKeyHandler = pluginKeyHandler
        textView.pluginIDs = pluginIDs
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
        textView.font = .systemFont(ofSize: 12, weight: .regular)
        textView.string = text
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = isEnabled
        textView.isSelectable = true

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PromptTextView else {
            return
        }

        textView.onSubmit = onSubmit
        textView.pluginKeyHandler = pluginKeyHandler
        textView.pluginIDs = pluginIDs
        textView.isEditable = isEnabled
        // Allow select/copy even when send is disabled; block typing via isEditable.
        textView.isSelectable = true

        if textView.string != text {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
        textView.applyPluginHighlighting()

        if isEnabled, context.coordinator.lastFocusedToken != focusToken {
            context.coordinator.lastFocusedToken = focusToken
            DispatchQueue.main.async {
                scrollView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var lastFocusedToken: Int = 0

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

struct PluginAutocompleteMenu: View {
    let matches: [String]
    let highlightedIndex: Int
    let onChoose: (String) -> Void

    private let accent = Color(red: 0.176, green: 0.286, blue: 0.576)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element) { index, pluginID in
                Button {
                    onChoose(pluginID)
                } label: {
                    Text("/\(pluginID)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == highlightedIndex ? accent.opacity(0.12) : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: accent.opacity(0.12), radius: 8, x: 0, y: 2)
    }
}

struct PromptCompletionCard: View {
    @MainActor
    enum CompletionStatus {
        case streaming
        case error
        case completed

        var displayString: String? {
            switch self {
            case .streaming: return "Thinking..."
            case .error: return "Error"
            case .completed: return nil
            }
        }
    }

    let turn: ChatTurn
    let isStreaming: Bool
    let isActiveStreamingTurn: Bool
    let completionStatus: CompletionStatus
    let statusMessage: String?
    let toolName: String?
    let onCopy: () -> Void
    @State private var isCompletionVisible = false

    init(
        turn: ChatTurn,
        isStreaming: Bool,
        isActiveStreamingTurn: Bool,
        completionStatus: CompletionStatus,
        statusMessage: String? = nil,
        toolName: String? = nil,
        onCopy: @escaping () -> Void
    ) {
        self.turn = turn
        self.isStreaming = isStreaming
        self.isActiveStreamingTurn = isActiveStreamingTurn
        self.completionStatus = completionStatus
        self.statusMessage = statusMessage
        self.toolName = toolName
        self.onCopy = onCopy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !turn.attachments.isEmpty
            {
                HStack {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        if !turn.attachments.isEmpty {
                            ChatFileAttachmentChipBar(attachments: turn.attachments)
                        }
                        if !turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(turn.prompt)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .trailing)
                }
            }

            if isCompletionVisible || !turn.response.isEmpty || isActiveStreamingTurn {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 10) {
                        if completionStatus == .streaming {
                            CompletionStatusView(status: statusMessage ?? "Thinking...", toolName: toolName)
                            if isActiveStreamingTurn {
                                let thought = turn.thought.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !thought.isEmpty {
                                    Text(thought)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: 720, alignment: .leading)
                                }
                            }
                        } else if let statusString = completionStatus.displayString {
                            CompletionStatusView(status: statusString, toolName: nil)
                        }

                        MarkdownResponseView(text: turn.response, allowsCSVExport: true)
                            .font(.system(size: 15))

                        if !isActiveStreamingTurn, !turn.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            HStack {
                                Button {
                                    onCopy()
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black.opacity(0.04))
                                )

                                Spacer()
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.45), value: isCompletionVisible)
        .onAppear {
            isCompletionVisible = !turn.response.isEmpty
        }
        .onChange(of: turn.response) { _, newValue in
            if newValue.isEmpty {
                isCompletionVisible = false
                return
            }

            if !isCompletionVisible {
                withAnimation(.easeInOut(duration: 0.45)) {
                    isCompletionVisible = true
                }
            }
        }
    }
}

private struct CompletionStatusView: View {
    let status: String
    let toolName: String?
    @State private var isVisible = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.35 + ((sin(t * 6) + 1) * 0.325) // 0.35...1.0

            HStack(spacing: 8) {
                Text("…")
                    .font(.system(size: 15, weight: .semibold))
                    .opacity(pulse)

                ZStack(alignment: .leading) {
                    Text(agentResponseStatusLabel(status: status) + (" \(toolName ?? "")"))
                        .id(status)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(.black.opacity(0.06), lineWidth: 1)
                        )
                        .transition(.opacity.combined(with: .offset(y: -3)))
                }
            }
            .foregroundStyle(.secondary)
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 2)
            .animation(.easeOut(duration: 0.18), value: status)
            .animation(.easeOut(duration: 0.18), value: isVisible)
            .onAppear {
                isVisible = true
            }
        }
        .padding(.top, 5)
        .padding(.bottom, 6)
    }
}
