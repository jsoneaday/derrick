import Combine
import DBRepository
import Foundation
import Plugin
import PolicyUserInteraction
import ServiceContracts

struct PluginSidebarItem: Identifiable, Hashable, Sendable {
    var id: String
    var enabled: Bool
    var version: String
    var description: String
}

@MainActor
final class PluginListStore: ObservableObject {
    static let shared = PluginListStore()

    @Published private(set) var plugins: [PluginSidebarItem] = []

    private var repository: DBRepository?

    private init() {}

    func configure(repository: DBRepository) async {
        self.repository = repository
        await reload()
    }

    func reload() async {
        guard let repository else { return }
        let rows = (try? await repository.listPlugins(includeDisabled: true)) ?? []
        var items: [PluginSidebarItem] = []
        for row in rows {
            var version = ""
            var description = ""
            if let versionID = row.currentVersionID,
               let ver = try? await repository.pluginVersion(id: versionID) {
                version = ver.version
                if let data = ver.manifestJSON.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    description = obj["description"] as? String ?? ""
                }
            }
            items.append(
                PluginSidebarItem(
                    id: row.id,
                    enabled: row.enabled,
                    version: version,
                    description: description
                )
            )
        }
        plugins = items
    }

    func slashMatches(handle: String) -> [PluginSidebarItem] {
        let enabled = plugins.filter(\.enabled)
        let ids = PluginPrefix.matches(handle: handle, pluginIDs: enabled.map(\.id))
        return ids.compactMap { id in enabled.first { $0.id.lowercased() == id } }
    }

    func setEnabled(id: String, enabled: Bool) async {
        guard let repository else { return }
        try? await repository.setPluginEnabled(id: id, enabled: enabled)
        await reload()
    }

    func installDailyNewsSample() async -> String? {
        guard let repository else { return "Database is not ready." }
        var draft = DailyNewsSample.draft()
        draft.reviewPassed = true
        draft.reviewSummary = "Shipped sample."
        draft.harnessPassed = true
        draft.lastHarnessSummary = "Shipped sample."
        let event = PolicyUserEventFactory.pluginInstall(
            pluginID: draft.pluginID,
            version: draft.version,
            summary: "Install \(draft.pluginID)? \(draft.description)",
            detail: draft.installSummary(),
            payloadPreview: draft.handle,
            toolName: AllowedMCPToolName.factoryInstallSample
        )
        let decision = await PolicyDecisionRouting.requestDecision(event)
        switch decision {
        case .approved, .approvedOnce, .approvedPermanently:
            break
        case .denied, .dismissed, .timedOut:
            return "Install cancelled."
        }
        do {
            try await promoteDraft(draft, repository: repository)
            await reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func promoteDraft(_ draft: FactoryPackageDraft, repository: DBRepository) async throws {
        let hash = try draft.contentHash()
        let manifest = try draft.pluginJSON()
        let runtime = try draft.runtimeJSON()
        let depsData = try JSONSerialization.data(withJSONObject: draft.dependencies)
        let depsJSON = String(decoding: depsData, as: UTF8.self)
        let existingVersions = try await repository.listPluginVersions(pluginID: draft.pluginID)
        let reusedID = existingVersions.first(where: { $0.version == draft.version })?.id
        let version = PluginVersionRow(
            id: reusedID ?? UUID().uuidString,
            pluginID: draft.pluginID,
            version: draft.version,
            contentHash: hash.rawValue,
            status: "promoted",
            manifestJSON: manifest,
            runtimeJSON: runtime,
            dependenciesJSON: depsJSON,
            entrypointSource: draft.handle
        )
        var plugin = try await repository.plugin(id: draft.pluginID)
            ?? PluginRow(id: draft.pluginID, enabled: true)
        if let previousID = plugin.currentVersionID,
           var previous = try await repository.pluginVersion(id: previousID) {
            previous.status = "superseded"
            try await repository.upsertPluginVersion(previous)
        }
        try await repository.upsertPluginVersion(version)
        plugin.enabled = true
        plugin.currentVersionID = version.id
        plugin.updatedAt = .now
        try await repository.upsertPlugin(plugin)
        try await repository.upsertPluginGrant(
            PluginGrantRow(
                pluginID: draft.pluginID,
                versionID: version.id,
                dependenciesJSON: depsJSON
            )
        )
    }
}

private enum AllowedMCPToolName {
    static let factoryInstallSample = "factory.install_sample"
}
