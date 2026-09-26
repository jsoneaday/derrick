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
    @State private var draftAlias = ""
    @State private var draftInstructions = ""
    @State private var draftModel: LLMModelChoice = .defaultHelperModel
    @State private var draftThinking: ModelThinkingOption = OpenAIModel.gpt56Luna.defaultThinkingOption
    @State private var draftRAG = AgentProfileRAGConfig.default
    @State private var draftEnabled = true
    @State private var draftCapabilities = AgentProfileCapabilities()
    @State private var editorError: String?
    @State private var saveBanner: SaveBanner?
    @ObservedObject private var plugins = PluginFactoryListStore.shared

    private struct SaveBanner: Equatable {
        let id: UUID
        let text: String
        let kind: InAppNotificationKind
    }

    private var selectedProfile: AgentProfile? {
        guard let selectedProfileID else { return nil }
        return store.profiles.first { $0.id == selectedProfileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            header
            HStack(alignment: .top, spacing: 20) {
                profileList
                    .frame(width: 240)
                ScrollView {
                    if selectedProfile != nil {
                        editor
                    } else {
                        Text("Select a profile to edit.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let editorError {
                Text(editorError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0))
        .overlay(alignment: .top) {
            if let saveBanner {
                InAppNotificationToast(text: saveBanner.text, kind: saveBanner.kind) {
                    self.saveBanner = nil
                }
                .padding(.top, 12)
            }
        }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            Text("A profile is who answers. In chat or a connector, start a message with $ and its alias, like $orchestrator. Mentioning an alias later in a sentence does not switch profiles.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profiles")
                .font(.headline)
            List(selection: $selectedProfileID) {
                ForEach(store.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                            Text("$" + (profile.alias ?? profile.handle))
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
                        .buttonStyle(.borderless)
                        .help("Edit")
                        Button {
                            duplicate(profile)
                        } label: {
                            Image(systemName: "plus.square.on.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Duplicate")
                    }
                    .tag(profile.id)
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)

            if let selectedProfile, !selectedProfile.isBuiltin {
                Button("Delete", role: .destructive) {
                    Task { await deleteSelected() }
                }
            }
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
                title: "Alias",
                caption: "Optional short address. If this is orc, $orc reaches this profile. $\(selectedProfile?.handle ?? "orchestrator") still works. Letters, numbers, and underscores only."
            ) {
                TextField("", text: $draftAlias)
                    .textFieldStyle(.roundedBorder)
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

            profileField(
                title: "RAG",
                caption: "Default retrieval instructions are the built-in session memory guide: when to use tools, and not to invent live facts from model memory."
            ) {
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
                    .onChange(of: draftCapabilities.allowsSubagent) { _, isSubagent in
                        if isSubagent {
                            draftCapabilities.allowedSubagentHandles = []
                        }
                    }
                if draftCapabilities.allowsSubagent {
                    Text("Subagents cannot call their own subagents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Profiles this one may call")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(store.profiles.filter { $0.handle != draftHandle && $0.capabilities.allowsSubagent }) { other in
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
            }

            profileField(title: "Job scheduling") {
                Toggle("Can schedule jobs", isOn: $draftCapabilities.allowsScheduling)
            }

            profileField(title: "Plugins") {
                Toggle("All plugins", isOn: Binding(
                    get: { draftCapabilities.allowsAllPlugins },
                    set: { isOn in
                        draftCapabilities.allowsAllPlugins = isOn
                        if isOn {
                            draftCapabilities.allowedPluginIDs = plugins.pluginIDs
                        }
                    }
                ))
                if plugins.pluginIDs.isEmpty {
                    Text("No plugins installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(plugins.pluginIDs, id: \.self) { pluginID in
                    Toggle(pluginID, isOn: Binding(
                        get: {
                            draftCapabilities.allowsAllPlugins
                                || draftCapabilities.allowedPluginIDs.contains(pluginID)
                        },
                        set: { isOn in
                            if draftCapabilities.allowsAllPlugins {
                                draftCapabilities.allowedPluginIDs = plugins.pluginIDs
                                draftCapabilities.allowsAllPlugins = false
                            }
                            if isOn {
                                if !draftCapabilities.allowedPluginIDs.contains(pluginID) {
                                    draftCapabilities.allowedPluginIDs.append(pluginID)
                                }
                            } else {
                                draftCapabilities.allowedPluginIDs.removeAll { $0 == pluginID }
                            }
                            if Set(draftCapabilities.allowedPluginIDs) == Set(plugins.pluginIDs),
                               !plugins.pluginIDs.isEmpty {
                                draftCapabilities.allowsAllPlugins = true
                            }
                        }
                    ))
                }
            }

            Toggle("Enabled", isOn: $draftEnabled)
                .disabled(selectedProfile?.handle == AgentProfileHandle.orchestrator)

            HStack {
                Spacer(minLength: 12)
                Button("Save profile") {
                    Task { await saveDraft() }
                }
                .buttonStyle(ModalPrimaryButtonStyle())
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
        let ids = store.profiles.map(\.id)
        if selectedProfileID == nil || !ids.contains(selectedProfileID ?? "") {
            selectedProfileID = ids.first
        }
        loadDraftFromSelection()
    }

    private func loadDraftFromSelection() {
        guard let profile = selectedProfile else { return }
        draftDisplayName = profile.displayName
        draftHandle = profile.handle
        draftAlias = profile.alias ?? ""
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
        let displayName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = draftAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = draftInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = validationError(displayName: displayName, alias: alias, instructions: instructions, profileID: profile.id) {
            editorError = message
            presentSaveBanner(message, kind: .failure)
            return
        }
        profile.displayName = displayName
        profile.handle = draftHandle
        profile.alias = alias.isEmpty ? nil : alias
        profile.instructions = instructions
        profile.modelJSON = (try? JSONEncoder().encode(draftModel)) ?? profile.modelJSON
        profile.thinkingJSON = try? JSONEncoder().encode(draftThinking)
        profile.rag = draftRAG
        var capabilities = draftCapabilities
        if capabilities.allowsSubagent {
            capabilities.allowedSubagentHandles = []
        }
        profile.capabilities = capabilities
        draftCapabilities = capabilities
        profile.isEnabled = draftEnabled
        do {
            let saved = try await store.upsert(profile)
            selectedProfileID = saved.id
            presentSaveBanner("Profile saved.", kind: .success)
        } catch {
            editorError = error.localizedDescription
            presentSaveBanner(error.localizedDescription, kind: .failure)
        }
    }

    private func validationError(
        displayName: String,
        alias: String,
        instructions: String,
        profileID: String
    ) -> String? {
        if displayName.isEmpty {
            return "Display name is required."
        }
        let displayKey = displayName.lowercased()
        if store.profiles.contains(where: {
            $0.id != profileID && $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == displayKey
        }) {
            return "Display name is already used."
        }
        if !alias.isEmpty {
            guard let normalized = AgentProfileHandle.normalize(alias) else {
                return "Alias must use letters, numbers, and underscores."
            }
            if store.profiles.contains(where: {
                $0.id != profileID && ($0.handle == normalized || $0.alias == normalized)
            }) {
                return "Alias is already used."
            }
        }
        if instructions.isEmpty {
            return "agents.md cannot be empty."
        }
        return nil
    }

    private func presentSaveBanner(_ text: String, kind: InAppNotificationKind) {
        let banner = SaveBanner(id: UUID(), text: text, kind: kind)
        saveBanner = banner
        Task {
            try? await Task.sleep(for: .seconds(3))
            if saveBanner?.id == banner.id {
                saveBanner = nil
            }
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
