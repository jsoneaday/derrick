//
//  PromptView.swift
//  ui
//
//  Created by David Choi on 7/4/26.
//

import SwiftUI

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

struct PromptInputView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let focusToken: Int

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
        textView.font = .systemFont(ofSize: 12, weight: .regular)
        textView.string = text
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

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

        if textView.string != text {
            textView.string = text
        }

        if context.coordinator.lastFocusedToken != focusToken {
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
    let onCopy: () -> Void
    @State private var isCompletionVisible = false

    init(
        turn: ChatTurn,
        isStreaming: Bool,
        isActiveStreamingTurn: Bool,
        completionStatus: CompletionStatus,
        statusMessage: String? = nil,
        onCopy: @escaping () -> Void
    ) {
        self.turn = turn
        self.isStreaming = isStreaming
        self.isActiveStreamingTurn = isActiveStreamingTurn
        self.completionStatus = completionStatus
        self.statusMessage = statusMessage
        self.onCopy = onCopy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    Text(turn.prompt)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: 720, alignment: .trailing)
                        .textSelection(.enabled)
                }
            }

            if isCompletionVisible || !turn.response.isEmpty || isActiveStreamingTurn {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 10) {
                        if completionStatus == .streaming {
                            Text("streaming")
                            CompletionStatusView(status: statusMessage ?? "Thinking...")
                        } else if let statusString = completionStatus.displayString {
                            CompletionStatusView(status: statusString)
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
                    Text(status)
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
