import Combine
import DBRepository
import Foundation
import Structure

@MainActor
final class PluginFactoryListStore: ObservableObject {
    static let shared = PluginFactoryListStore()

    @Published private(set) var releases: [PluginFactoryReleaseSummary] = []
    @Published private(set) var skillIndex: [PluginSkillDisclosure.IndexEntry] = []
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

    /// Progressive disclosure block for chat system prompts (names + descriptions only).
    var skillIndexPromptBlock: String {
        PluginSkillDisclosure.indexPromptBlock(entries: skillIndex)
    }

    func configure(repository: DBRepository) async {
        self.repository = repository
        await purgeLegacySlackConnectors()
        await reload()
    }

    func reload() async {
        guard let repository else { return }
        lastError = nil
        releases = (try? await repository.listPluginFactoryReleaseSummaries()) ?? []
        await refreshSkillIndex()
    }

    func release(pluginID: String, version: String) async throws -> PluginFactoryRelease? {
        guard let repository else { return nil }
        return try await repository.pluginFactoryRelease(pluginID: pluginID, version: version)
    }

    func replace(_ release: PluginFactoryRelease) async throws {
        guard let repository else {
            throw DBRepositoryError.sqliteOperationFailed("Plugin factory repository is not configured.")
        }
        try await repository.replacePluginFactoryRelease(release)
        await reload()
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

    /// Removes legacy Slack reference connectors installed outside the LLM create path.
    func purgeLegacySlackConnectors() async {
        guard let repository else { return }
        do {
            let summaries = try await repository.listPluginFactoryReleaseSummaries()
            var pluginIDs = Set<String>()
            for summary in summaries where PluginFactoryLegacyPurge.isLegacySlackPluginID(summary.pluginID) {
                pluginIDs.insert(summary.pluginID)
            }
            for pluginID in pluginIDs {
                try await repository.deletePluginFactoryRelease(pluginID: pluginID)
            }
            let connectors = try await repository.listMessagingConnectors()
            let keep = Set(
                connectors
                    .map(\.pluginID)
                    .filter { !PluginFactoryLegacyPurge.isLegacySlackPluginID($0) }
            )
            try await repository.pruneMessagingConnectors(keeping: keep)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshSkillIndex() async {
        var entries: [PluginSkillDisclosure.IndexEntry] = []
        for group in groups {
            guard let latest = group.latest,
                  let release = try? await release(pluginID: latest.pluginID, version: latest.version)
            else { continue }
            entries.append(contentsOf: PluginSkillDisclosure.index(from: release))
        }
        skillIndex = entries.sorted { lhs, rhs in
            if lhs.pluginID != rhs.pluginID { return lhs.pluginID < rhs.pluginID }
            return lhs.skillName < rhs.skillName
        }
    }
}

struct PluginFactoryReleaseGroup: Identifiable, Sendable {
    let pluginID: String
    let releases: [PluginFactoryReleaseSummary]

    var id: String { pluginID }
    var latest: PluginFactoryReleaseSummary? { releases.first }
}
