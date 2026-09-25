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
    @State private var draftCapabilities = AgentProfileCapabilities()
    @State private var editorError: String?

    private var selectedProfile: AgentProfile? {
        guard let selectedProfileID else { return nil }
        return store.profiles.first { $0.id == selectedProfileID }
    }

    var body: some View {
        ScrollView {
            editorPage
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0))
    }

    private var editorPage: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            HStack {
                Text("Profiles")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    addProfile()
                } label: {
                    Label("New", systemImage: "plus")
                }
            }

            Text("A profile is who answers. In chat or a connector, start a message with $ and its short name, like $orchestrator. Mentioning a short name later in a sentence does not switch profiles.")
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
                                        .foregroundStyle(AgentProfileTokenColor.darkGreen)
                                }
                                Spacer(minLength: 0)
                                if !profile.isEnabled {
                                    Text("Off")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    selectedProfileID = profile.id
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                .help("Edit")
                                Button {
                                    duplicate(profile)
                                } label: {
                                    Image(systemName: "plus.square.on.square")
                                }
                                .buttonStyle(.plain)
                                .help("Duplicate")
                            }
                            .tag(profile.id as String?)
                        }
                    }
                    .frame(minHeight: 180)

                    if let selectedProfile, !selectedProfile.isBuiltin {
                        Button("Delete", role: .destructive) {
                            Task { await deleteSelected() }
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
        .padding(24)
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
                title: "Short name",
                caption: "Talk to this profile with $ plus this name at the start of a message, like $orchestrator. Letters, numbers, and underscores only."
            ) {
                TextField("reviewer", text: $draftHandle)
                    .textFieldStyle(.roundedBorder)
                    .disabled(selectedProfile?.isBuiltin == true)
            }

            profileField(
                title: "agents.md",
                caption: "What this profile is for. This text is its instructions."
            ) {
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

            profileField(title: "Subagents") {
                Toggle("Can be called as a subagent", isOn: $draftCapabilities.allowsSubagent)
                Text("Profiles this one may call")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(store.profiles.filter { $0.handle != draftHandle }) { other in
                    Toggle(other.displayName, isOn: Binding(
                        get: { draftCapabilities.allowedSubagentHandles.contains(other.handle) },
                        set: { isOn in
                            if isOn {
                                if !draftCapabilities.allowedSubagentHandles.contains(other.handle) {
                                    draftCapabilities.allowedSubagentHandles.append(other.handle)
                                }
                            } else {
                                draftCapabilities.allowedSubagentHandles.removeAll { $0 == other.handle }
                            }
                        }
                    ))
                }
                Stepper(
                    "At once: \(draftCapabilities.maxSimultaneousSubagents)",
                    value: $draftCapabilities.maxSimultaneousSubagents,
                    in: 1...8
                )
            }

            Toggle("Can schedule jobs", isOn: $draftCapabilities.allowsScheduling)

            profileField(title: "Plugins") {
                Toggle("All installed plugins", isOn: $draftCapabilities.allowsAllPlugins)
                if !draftCapabilities.allowsAllPlugins {
                    ForEach(PluginFactoryListStore.shared.pluginIDs, id: \.self) { pluginID in
                        Toggle(pluginID, isOn: Binding(
                            get: { draftCapabilities.allowedPluginIDs.contains(pluginID) },
                            set: { isOn in
                                if isOn {
                                    if !draftCapabilities.allowedPluginIDs.contains(pluginID) {
                                        draftCapabilities.allowedPluginIDs.append(pluginID)
                                    }
                                } else {
                                    draftCapabilities.allowedPluginIDs.removeAll { $0 == pluginID }
                                }
                            }
                        ))
                    }
                }
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
        draftCapabilities = profile.capabilities
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
        profile.capabilities = draftCapabilities
        profile.isEnabled = draftEnabled
        do {
            let saved = try await store.upsert(profile)
            selectedProfileID = saved.id
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func duplicate(_ profile: AgentProfile) {
        var copy = profile
        copy = AgentProfile(
            displayName: "Copy of \(profile.displayName)",
            handle: uniqueHandle(basedOn: profile.handle),
            instructions: profile.instructions,
            modelJSON: profile.modelJSON,
            thinkingJSON: profile.thinkingJSON,
            rag: profile.rag,
            capabilities: profile.capabilities,
            isEnabled: profile.isEnabled,
            isBuiltin: false
        )
        Task {
            do {
                let saved = try await store.upsert(copy)
                selectedProfileID = saved.id
            } catch {
                editorError = error.localizedDescription
            }
        }
    }

    private func uniqueHandle(basedOn handle: String) -> String {
        var candidate = "\(handle)_copy"
        var suffix = 2
        let taken = Set(store.profiles.map(\.handle))
        while taken.contains(candidate) {
            candidate = "\(handle)_copy_\(suffix)"
            suffix += 1
        }
        return candidate
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
