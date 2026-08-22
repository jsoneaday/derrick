import Combine
import DBRepository
import Foundation
import Plugin

@MainActor
final class PluginFactoryListStore: ObservableObject {
    static let shared = PluginFactoryListStore()

    @Published private(set) var releases: [PluginFactoryReleaseSummary] = []
    @Published private(set) var lastError: String?

    private var repository: DBRepository?

    private init() {}

    func configure(repository: DBRepository) async {
        self.repository = repository
        await reload()
    }

    func reload() async {
        guard let repository else { return }
        lastError = nil
        let userReleases = (try? await repository.listPluginFactoryReleaseSummaries()) ?? []
        let systemReleases = [
            PluginFactoryReleaseSummary(
                pluginID: "create-plugin",
                version: "system",
                contentHash: "",
                reviewSummary: "Starts the plugin creation flow.",
                isSystem: true
            ),
            PluginFactoryReleaseSummary(
                pluginID: "edit-plugin",
                version: "system",
                contentHash: "",
                reviewSummary: "Edits an existing plugin through the factory.",
                isSystem: true
            ),
        ]
        let systemIDs = Set(systemReleases.map(\.pluginID))
        let latestUserReleases = Dictionary(
            userReleases.filter { !systemIDs.contains($0.pluginID) }.map { ($0.pluginID, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.pluginID < $1.pluginID }
        releases = systemReleases.sorted { $0.pluginID < $1.pluginID }
            + latestUserReleases
    }

    func delete(_ release: PluginFactoryReleaseSummary) async {
        guard !release.isSystem, let repository else { return }
        do {
            try await repository.deletePluginFactoryRelease(
                pluginID: release.pluginID
            )
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
