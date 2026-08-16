import SwiftUI

struct CreatePluginWizardView: View {
    @ObservedObject var store: CreatePluginWizardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What should this plugin do?")
                    .font(.subheadline.weight(.semibold))
                Text("In your words. Include what chat should do after it runs, if anything — for example “get the latest news links, then summarize them.”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $store.request)
                    .font(.body)
                    .frame(minHeight: 96)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .disabled(store.phase == .reviewing)
            }

            if store.phase == .reviewing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking that this works as a plugin…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = store.reviewError, !error.isEmpty {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let review = store.review, store.phase == .reviewed {
                reviewBlock(review)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func reviewBlock(_ review: CreatePluginPromptReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(review.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if !review.pluginDoes.isEmpty {
                labeled("Plugin", review.pluginDoes)
            }
            if !review.chatDoes.isEmpty {
                labeled("After it runs", review.chatDoes)
            }
            ForEach(Array(review.questions.enumerated()), id: \.offset) { _, question in
                Text(question)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(review.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Create plugin to start building. You can add a detail in the box first if you want.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .labelColor).opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func labeled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CreatePluginWizardFooter: View {
    @ObservedObject var store: CreatePluginWizardStore
    var settings: LLMModelSettings
    var onCreate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Cancel") {
                store.dismiss()
            }
            .buttonStyle(ModalSecondaryButtonStyle())
            .disabled(store.phase == .reviewing)
            .keyboardShortcut(.cancelAction)

            Button(primaryTitle) {
                Task {
                    if await store.submit(settings: settings) {
                        onCreate()
                    }
                }
            }
            .buttonStyle(ModalPrimaryButtonStyle())
            .disabled(!store.canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    private var primaryTitle: String {
        if store.phase == .reviewing { return "Submitting…" }
        if store.review != nil { return "Create plugin" }
        return "Submit plugin"
    }
}
