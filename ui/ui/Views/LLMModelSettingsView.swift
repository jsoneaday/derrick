import SwiftUI
import DBRepository

private enum LLMModelSettingsSidebarItem: String, CaseIterable, Identifiable, Hashable {
    case helperModels
    case networkAccess
    case sensitiveContent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .helperModels:
            return "Select helper models"
        case .networkAccess:
            return "Network access"
        case .sensitiveContent:
            return "Sensitive content"
        }
    }

    var systemImage: String {
        switch self {
        case .helperModels:
            return "brain.head.profile"
        case .networkAccess:
            return "network"
        case .sensitiveContent:
            return "eye.slash"
        }
    }
}

struct LLMModelSettingsView: View {
    @ObservedObject var helperModelSettings: LLMModelSettings
    @ObservedObject private var egressAllowlist = EgressAllowlistService.shared
    @ObservedObject private var contentSensitivity = ContentSensitivityGrantService.shared
    @State private var selectedItem: LLMModelSettingsSidebarItem = .helperModels
    @State private var newSuffixDraft = ""
    @State private var networkError: String?
    @State private var contentError: String?

    var body: some View {
        // Prefer a plain HStack over NavigationSplitView: split views often leave a blank
        // detail column when hosted in a free-floating NSWindow.
        HStack(spacing: 0) {
            List(selection: $selectedItem) {
                ForEach(LLMModelSettingsSidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)
            .frame(maxHeight: .infinity)

            Divider()

            Group {
                switch selectedItem {
                case .helperModels:
                    helperModelDetail
                case .networkAccess:
                    networkAccessDetail
                case .sensitiveContent:
                    sensitiveContentDetail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 440)
    }

    @ViewBuilder
    private var helperModelDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Helper models")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("Choose the models Derrick uses for memory summarization and Python script review.")
                .foregroundStyle(.secondary)

            Form {
                Section("Summarizer model") {
                    helperModelPicker(
                        selection: $helperModelSettings.summarizerModel,
                        accessibilityLabel: "Summarizer model"
                    )
                }

                Section("Python script reviewer model") {
                    helperModelPicker(
                        selection: $helperModelSettings.pythonScriptReviewerModel,
                        accessibilityLabel: "Python script reviewer model"
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var networkAccessDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Network access")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("Domain suffixes the egress proxy may reach from network-enabled scripts. Private and metadata hosts stay blocked.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("example.com", text: $newSuffixDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await addSuffix() } }
                Button("Add") {
                    Task { await addSuffix() }
                }
                .disabled(newSuffixDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let networkError {
                Text(networkError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if egressAllowlist.suffixes.isEmpty {
                Text("No allowed domain suffixes yet. Seeded defaults appear after first app launch, or add a domain above.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(egressAllowlist.suffixes) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.suffix)
                                        .font(.body.monospaced())
                                    Text(row.source == "seed" ? "Default" : "User")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !row.enabled {
                                    Text("Disabled")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button(role: .destructive) {
                                    Task {
                                        do {
                                            try await egressAllowlist.removeSuffix(id: row.id)
                                            networkError = nil
                                        } catch {
                                            networkError = error.localizedDescription
                                        }
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var sensitiveContentDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sensitive content")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("When a reply may include sensitive data, Derrick can ask before showing it. Always-allow matches the “Always” button on those prompts.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let contentError {
                Text(contentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Form {
                ForEach(ContentSensitivityGrantService.grantableCategories, id: \.id) { item in
                    Toggle(
                        isOn: Binding(
                            get: { contentSensitivity.isPermanentlyGranted(item.id) },
                            set: { newValue in
                                Task {
                                    do {
                                        try await contentSensitivity.setPermanentGrant(
                                            category: item.id,
                                            enabled: newValue
                                        )
                                        contentError = nil
                                    } catch {
                                        contentError = error.localizedDescription
                                    }
                                }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Always allow \(item.title.lowercased())")
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Social Security–like numbers")
                            .font(.body)
                        Text("Always blocked by policy. Not overridable here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func addSuffix() async {
        let draft = newSuffixDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        do {
            try await egressAllowlist.addSuffix(draft, source: "user")
            newSuffixDraft = ""
            networkError = nil
        } catch {
            networkError = error.localizedDescription
        }
    }

    private func helperModelPicker(
        selection: Binding<LLMModelChoice>,
        accessibilityLabel: String
    ) -> some View {
        Picker(accessibilityLabel, selection: selection) {
            ForEach(LLMModelChoice.allCases) { model in
                Text(model.helperDisplayName).tag(model)
            }
        }
        .pickerStyle(.menu)
    }
}

#Preview {
    let config = DBRepositoryConfiguration(
        applicationName: "preview",
        databaseName: "preview",
        databaseDirectoryURL: FileManager.default.temporaryDirectory,
        username: "ui",
        password: "ui"
    )
    LLMModelSettingsView(helperModelSettings: LLMModelSettings(repository: DBRepository(configuration: config)))
}
