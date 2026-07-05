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
    let turn: ChatTurn
    let isStreaming: Bool
    let isActiveStreamingTurn: Bool
    let completionStatus: String?
    let onCopy: () -> Void
    @State private var isCompletionVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Prompt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Copy") {
                    onCopy()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(turn.prompt)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if isCompletionVisible || !turn.response.isEmpty || isActiveStreamingTurn {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Completion")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if let completionStatus {
                            CompletionStatusView(status: completionStatus)
                        }

                        MarkdownResponseView(text: turn.response)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.985, anchor: .top)))
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
