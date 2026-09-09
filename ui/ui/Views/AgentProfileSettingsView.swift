import DBRepository
import LLMAgentClient
import Structure
import SwiftUI

struct AgentProfileSettingsView: View {
    @ObservedObject private var store = AgentProfileStore.shared
    @ObservedObject var helperModelSettings: LLMModelSettings
    @ObservedObject var modelThinkingSettings: LLMModelThinkingSettings

    @State private var selectedProfileID: String?
    @State private var draftDisplayName = ""
    @State private var draftHandle = ""
    @State private var draftInstructions = ""
    @State private var draftModel: LLMModelChoice = .defaultHelperModel
    @State private var draftThinking: ModelThinkingOption = OpenAIModel.gpt56Luna.defaultThinkingOption
    @State private var draftRAG = AgentProfileRAGConfig.default
    @State private var draftEnabled = true
    @State private var editorError: String?

    private var selectedProfile: AgentProfile? {
        guard let selectedProfileID else { return nil }
        return store.profiles.first { $0.id == selectedProfileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text("Agent profiles")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("Profiles define how Derrick behaves when you message an agent from connectors. Address a profile with $handle (for example $orchestrator). Replies are posted as [\(DerrickAppSupport.hostAppProductName)].")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Profiles")
                        .font(.headline)
                    List(selection: $selectedProfileID) {
                        ForEach(store.profiles) { profile in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayName)
                                    Text("$" + profile.handle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if !profile.isEnabled {
                                    Text("Off")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(profile.id as String?)
                        }
                    }
                    .frame(minHeight: 180, maxHeight: 260)

                    HStack {
                        Button("Add profile") {
                            addProfile()
                        }
                        if let selectedProfile, !selectedProfile.isBuiltin {
                            Button("Delete", role: .destructive) {
                                Task { await deleteSelected() }
                            }
                        }
                    }
                }
                .frame(width: 240)

                if selectedProfile != nil {
                    editor
                } else {
                    Text("Select a profile to edit.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let editorError {
                Text(editorError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            syncSelection()
        }
        .onChange(of: store.profiles) { _, _ in
            syncSelection()
        }
        .onChange(of: selectedProfileID) { _, _ in
            loadDraftFromSelection()
        }
    }

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            profileField(title: "Display name") {
                TextField("Reviewer", text: $draftDisplayName)
                    .textFieldStyle(.roundedBorder)
            }

            profileField(
                title: "Handle",
                caption: "Use as $handle in messages. Letters, numbers, and underscores only."
            ) {
                TextField("reviewer", text: $draftHandle)
                    .textFieldStyle(.roundedBorder)
                    .disabled(selectedProfile?.isBuiltin == true)
            }

            profileField(title: "Instructions") {
                TextEditor(text: $draftInstructions)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }

            profileField(title: "Model") {
                Picker("Model", selection: $draftModel) {
                    ForEach(LLMModelChoice.allCases) { model in
                        Text(model.helperDisplayName).tag(model)
                    }
                }
                .labelsHidden()
                .onChange(of: draftModel) { _, newModel in
                    if !newModel.thinkingOptions.contains(where: { $0.id == draftThinking.id }) {
                        draftThinking = newModel.defaultThinkingOption
                    }
                }
            }

            if !draftModel.thinkingOptions.isEmpty {
                profileField(
                    title: "Thinking level",
                    caption: "Reasoning depth for this profile's model."
                ) {
                    Picker("Thinking level", selection: Binding(
                        get: { draftThinking.id },
                        set: { newID in
                            if let option = draftModel.thinkingOptions.first(where: { $0.id == newID }) {
                                draftThinking = option
                            }
                        }
                    )) {
                        ForEach(draftModel.thinkingOptions, id: \.id) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            profileField(title: "RAG") {
                Toggle("Use default retrieval instructions", isOn: $draftRAG.useDefaultInstructions)
                if !draftRAG.useDefaultInstructions {
                    TextEditor(text: Binding(
                        get: { draftRAG.customInstructions ?? "" },
                        set: { draftRAG.customInstructions = $0 }
                    ))
                    .font(.body)
                    .frame(minHeight: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                }
                Toggle("Include session memory", isOn: $draftRAG.useSessionMemory)
                Stepper(
                    "Retrieval limit: \(draftRAG.retrievalLimit)",
                    value: $draftRAG.retrievalLimit,
                    in: 0 ... 20
                )
            }

            Toggle("Enabled", isOn: $draftEnabled)
                .disabled(selectedProfile?.handle == AgentProfileHandle.orchestrator)

            HStack {
                Spacer(minLength: 12)
                Button("Save profile") {
                    Task { await saveDraft() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func profileField<C: View>(
        title: String,
        caption: String? = nil,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.headerControlSpacing) {
            Text(title)
                .font(.headline)
            content()
                .padding(.leading, SettingsLayout.fieldIndent)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, SettingsLayout.fieldIndent)
            }
        }
    }

    private func syncSelection() {
        if selectedProfileID == nil {
            selectedProfileID = store.profiles.first?.id
        } else if store.profiles.contains(where: { $0.id == selectedProfileID }) == false {
            selectedProfileID = store.profiles.first?.id
        }
        loadDraftFromSelection()
    }

    private func loadDraftFromSelection() {
        guard let profile = selectedProfile else { return }
        draftDisplayName = profile.displayName
        draftHandle = profile.handle
        draftInstructions = profile.instructions
        draftModel = (try? JSONDecoder().decode(LLMModelChoice.self, from: profile.modelJSON)) ?? .defaultHelperModel
        draftThinking = profile.thinkingJSON.flatMap {
            try? JSONDecoder().decode(ModelThinkingOption.self, from: $0)
        } ?? draftModel.defaultThinkingOption
        draftRAG = profile.rag
        draftEnabled = profile.isEnabled
        editorError = nil
    }

    private func addProfile() {
        let modelJSON = (try? JSONEncoder().encode(LLMModelChoice.defaultHelperModel)) ?? Data()
        let profile = AgentProfile(
            displayName: "New profile",
            handle: "profile_\(store.profiles.count + 1)",
            instructions: "",
            modelJSON: modelJSON
        )
        Task {
            do {
                let saved = try await store.upsert(profile)
                selectedProfileID = saved.id
            } catch {
                editorError = error.localizedDescription
            }
        }
    }

    private func saveDraft() async {
        guard var profile = selectedProfile else { return }
        editorError = nil
        profile.displayName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.handle = draftHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.instructions = draftInstructions
        profile.modelJSON = (try? JSONEncoder().encode(draftModel)) ?? profile.modelJSON
        profile.thinkingJSON = try? JSONEncoder().encode(draftThinking)
        profile.rag = draftRAG
        profile.isEnabled = draftEnabled
        do {
            let saved = try await store.upsert(profile)
            selectedProfileID = saved.id
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        guard let profile = selectedProfile, !profile.isBuiltin else { return }
        do {
            try await store.delete(id: profile.id)
            selectedProfileID = store.profiles.first?.id
        } catch {
            editorError = error.localizedDescription
        }
    }
}
