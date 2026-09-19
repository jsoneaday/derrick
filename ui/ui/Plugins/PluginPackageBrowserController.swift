import Combine
import DBRepository
import Foundation
import Structure

@MainActor
final class PluginPackageBrowserController: ObservableObject {
    @Published private(set) var groups: [PluginFactoryReleaseGroup] = []
    @Published var expandedPluginIDs: Set<String> = []
    @Published var selectedPluginID: String?
    @Published var selectedVersion: String?
    @Published var selectedFilePath: String?
    @Published private(set) var filePaths: [String] = []
    @Published private(set) var fileBodies: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published var editPrompt: String = ""
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private var loadedRelease: PluginFactoryRelease?

    var selectedFileText: String {
        guard let path = selectedFilePath else { return "" }
        return fileBodies[path] ?? ""
    }

    var canSubmitEdit: Bool {
        selectedPluginID != nil
            && selectedVersion != nil
            && !editPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reloadList() async {
        await PluginFactoryListStore.shared.reload()
        groups = PluginFactoryListStore.shared.groups
        if let selectedPluginID,
           !groups.contains(where: { $0.pluginID == selectedPluginID }) {
            clearSelection()
        } else if let selectedPluginID, let selectedVersion {
            await loadRelease(pluginID: selectedPluginID, version: selectedVersion)
        }
    }

    func selectPlugin(_ pluginID: String) async {
        expandedPluginIDs.insert(pluginID)
        guard let group = groups.first(where: { $0.pluginID == pluginID }),
              let latest = group.latest
        else {
            selectedPluginID = pluginID
            selectedVersion = nil
            clearEditor()
            return
        }
        selectedPluginID = pluginID
        await selectVersion(latest.version, pluginID: pluginID)
    }

    func selectVersion(_ version: String, pluginID: String? = nil) async {
        let pluginID = pluginID ?? selectedPluginID
        guard let pluginID else { return }
        selectedPluginID = pluginID
        selectedVersion = version
        expandedPluginIDs.insert(pluginID)
        await loadRelease(pluginID: pluginID, version: version)
    }

    func selectFile(_ path: String) {
        selectedFilePath = path
        statusMessage = nil
        errorMessage = nil
    }

    /// Starts an LLM edit turn for the selected plugin. Promotes a new version on success.
    func submitEditPrompt() {
        let prompt = editPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pluginID = selectedPluginID,
              let version = selectedVersion,
              !prompt.isEmpty
        else { return }
        NotificationCenter.default.post(
            name: ChatShellNotification.startPluginEdit,
            object: nil,
            userInfo: [
                ChatShellNotification.pluginIDUserInfoKey: pluginID,
                ChatShellNotification.pluginVersionUserInfoKey: version,
                ChatShellNotification.editPromptUserInfoKey: prompt,
            ]
        )
        editPrompt = ""
        statusMessage = "Updating /\(pluginID)…"
    }

    /// Reloads list and focuses the newly saved version after a factory create/edit succeeds.
    func handleFactorySucceeded(pluginID: String, version: String?) async {
        await reloadList()
        if groups.contains(where: { $0.pluginID == pluginID }) {
            if let version, groups.first(where: { $0.pluginID == pluginID })?
                .releases.contains(where: { $0.version == version }) == true {
                await selectVersion(version, pluginID: pluginID)
            } else {
                await selectPlugin(pluginID)
            }
            statusMessage = "Updated /\(pluginID)" + (version.map { " v\($0)" } ?? "") + "."
            errorMessage = nil
        }
    }

    private func loadRelease(pluginID: String, version: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let release = try await PluginFactoryListStore.shared.release(
                pluginID: pluginID,
                version: version
            ) else {
                clearEditor()
                errorMessage = "Could not load \(pluginID) v\(version)."
                return
            }
            loadedRelease = release
            let files = release.browserPackageFiles()
            fileBodies = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.body) })
            filePaths = files.map(\.path)
            if let selectedFilePath, filePaths.contains(selectedFilePath) {
                // keep
            } else {
                selectedFilePath = filePaths.first
            }
        } catch {
            clearEditor()
            errorMessage = error.localizedDescription
        }
    }

    private func clearSelection() {
        selectedPluginID = nil
        selectedVersion = nil
        clearEditor()
    }

    private func clearEditor() {
        loadedRelease = nil
        filePaths = []
        fileBodies = [:]
        selectedFilePath = nil
    }
}
