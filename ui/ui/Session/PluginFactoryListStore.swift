import Combine
import DBRepository
import Foundation
import Plugin
import Structure

@MainActor
final class PluginFactoryListStore: ObservableObject {
    static let shared = PluginFactoryListStore()

    @Published private(set) var releases: [PluginFactoryReleaseSummary] = []
    @Published private(set) var lastError: String?

    private var repository: DBRepository?

    private init() {}

    var groups: [PluginFactoryReleaseGroup] {
        Dictionary(grouping: releases, by: \.pluginID)
            .map { PluginFactoryReleaseGroup(pluginID: $0.key, releases: $0.value) }
            .sorted { $0.pluginID < $1.pluginID }
    }

    var pluginIDs: [String] {
        groups.map(\.pluginID)
    }

    func configure(repository: DBRepository) async {
        self.repository = repository
        await reload()
    }

    func reload() async {
        guard let repository else { return }
        lastError = nil
        releases = (try? await repository.listPluginFactoryReleaseSummaries()) ?? []
    }

    func delete(_ release: PluginFactoryReleaseSummary) async {
        guard let repository else { return }
        do {
            try await repository.deletePluginFactoryRelease(
                pluginID: release.pluginID,
                version: release.version
            )
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct PluginFactoryReleaseGroup: Identifiable, Sendable {
    let pluginID: String
    let releases: [PluginFactoryReleaseSummary]

    var id: String { pluginID }
    var latest: PluginFactoryReleaseSummary? { releases.first }
}
