import DBRepository
import Foundation
import Structure

/// Deletes factory releases and messaging connectors for legacy Slack reference installs.
public enum LegacySlackConnectorPurge: Sendable {
    /// Returns how many factory release rows were deleted.
    @discardableResult
    public static func run(repository: DBRepository) async throws -> Int {
        let summaries = try await repository.listPluginFactoryReleaseSummaries()
        var pluginIDs = Set<String>()
        for summary in summaries where PluginFactoryLegacyPurge.isLegacySlackPluginID(summary.pluginID) {
            pluginIDs.insert(summary.pluginID)
        }
        var deletedReleases = 0
        for pluginID in pluginIDs.sorted() {
            let before = summaries.filter { $0.pluginID == pluginID }.count
            try await repository.deletePluginFactoryRelease(pluginID: pluginID)
            deletedReleases += before
        }

        let connectors = try await repository.listMessagingConnectors()
        let keep = Set(
            connectors
                .map(\.pluginID)
                .filter { !PluginFactoryLegacyPurge.isLegacySlackPluginID($0) }
        )
        try await repository.pruneMessagingConnectors(keeping: keep)
        return deletedReleases
    }
}
