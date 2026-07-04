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
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if isCompletionVisible || !turn.response.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    Text("Completion")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    MarkdownResponseView(text: turn.response)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
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
