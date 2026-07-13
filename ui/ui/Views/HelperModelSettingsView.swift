import SwiftUI

private enum HelperModelSettingsSidebarItem: String, CaseIterable, Identifiable {
    case helperModels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .helperModels:
            return "Select helper models"
        }
    }

    var systemImage: String {
        switch self {
        case .helperModels:
            return "brain.head.profile"
        }
    }
}

struct HelperModelSettingsView: View {
    @ObservedObject var helperModelSettings: HelperModelSettings
    @State private var selectedItem: HelperModelSettingsSidebarItem = .helperModels

    var body: some View {
        NavigationSplitView {
            List(HelperModelSettingsSidebarItem.allCases, selection: $selectedItem) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            helperModelDetail
                .padding(24)
        }
        .frame(width: 760, height: 440)
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
            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
    HelperModelSettingsView(helperModelSettings: HelperModelSettings())
}
