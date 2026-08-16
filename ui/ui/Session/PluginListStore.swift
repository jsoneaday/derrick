import Combine
import DBRepository
import DockerRunnerXPC
import Foundation
import Plugin
import PolicyUserInteraction
import ServiceContracts

struct PluginVersionItem: Identifiable, Hashable, Sendable {
    var id: String
    var version: String
    var status: String
    var isCurrent: Bool
}

struct PluginSidebarItem: Identifiable, Hashable, Sendable {
    var id: String
    var enabled: Bool
    var version: String
    var description: String
    var versions: [PluginVersionItem]
}

@MainActor
final class PluginListStore: ObservableObject {
    static let shared = PluginListStore()

    @Published private(set) var plugins: [PluginSidebarItem] = []

    private var repository: DBRepository?
    private var catalogObserver: DerrickDarwinNotifyObserver?

    private init() {}

    func configure(repository: DBRepository) async {
        self.repository = repository
        startCatalogObserver()
        await reload()
    }

    private func startCatalogObserver() {
        guard catalogObserver == nil else { return }
        let observer = DerrickDarwinNotifyObserver(
            darwinName: DerrickPluginCatalogSignal.darwinName,
            localName: DerrickPluginCatalogSignal.localName
        ) { [weak self] in
            Task { @MainActor in
                await self?.reload()
            }
        }
        observer.start()
        catalogObserver = observer
    }

    func reload() async {
        guard let repository else { return }
        let rows = (try? await repository.listPlugins(includeDisabled: true)) ?? []
        var items: [PluginSidebarItem] = []
        for row in rows {
            var version = ""
            var description = ""
            let history = (try? await repository.listPluginVersions(pluginID: row.id)) ?? []
            var current: PluginVersionRow?
            if let versionID = row.currentVersionID {
                current = history.first(where: { $0.id == versionID })
                if current == nil {
                    current = try? await repository.pluginVersion(id: versionID)
                }
            }
            if let ver = current {
                version = ver.version
                if let data = ver.manifestJSON.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    description = obj["description"] as? String ?? ""
                }
            }
            let versionItems = history.map { ver in
                PluginVersionItem(
                    id: ver.id,
                    version: ver.version,
                    status: ver.status,
                    isCurrent: ver.id == row.currentVersionID
                )
            }
            items.append(
                PluginSidebarItem(
                    id: row.id,
                    enabled: row.enabled,
                    version: version,
                    description: description,
                    versions: versionItems
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

    func delete(id: String) async -> String? {
        guard let repository else { return "Database is not ready." }
        do {
            let versions = try await repository.listPluginVersions(pluginID: id)
            var volumes = Set(versions.compactMap(\.volumeName).filter { !$0.isEmpty })
            volumes.insert(DerrickNamedVolume.pluginData(id: id))
            for version in versions {
                let hash8 = String(version.contentHash.prefix(8))
                volumes.insert(DerrickNamedVolume.pluginCode(id: id, hash8: hash8))
            }
            let result = try await repository.uninstallPlugin(id: id)
            volumes.formUnion(result.volumeNames)
            await XPCDockerRunner.shared.removeRemovableVolumes(Array(volumes))
            DerrickPluginCatalogSignal.post()
            await reload()
            return nil
        } catch {
            await reload()
            return error.localizedDescription
        }
    }

    func deleteVersion(id versionID: String, pluginID: String) async -> String? {
        guard let repository else { return "Database is not ready." }
        do {
            let version = try await repository.pluginVersion(id: versionID)
            var volumes = Set(version?.volumeName.map { [$0] } ?? [])
            if let version {
                let hash8 = String(version.contentHash.prefix(8))
                volumes.insert(DerrickNamedVolume.pluginCode(id: pluginID, hash8: hash8))
            }
            let result = try await repository.deletePluginVersion(id: versionID)
            volumes.formUnion(result.volumeNames)
            await XPCDockerRunner.shared.removeRemovableVolumes(Array(volumes))
            DerrickPluginCatalogSignal.post()
            await reload()
            return nil
        } catch {
            await reload()
            return error.localizedDescription
        }
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
            DerrickPluginCatalogSignal.post()
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
        let versionName = PluginReleaseVersion.assign(
            requested: draft.version,
            existing: existingVersions.map(\.version)
        )
        let version = PluginVersionRow(
            id: UUID().uuidString,
            pluginID: draft.pluginID,
            version: versionName,
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

/// Factory tools run in the daemon. Traces land in `service_logs`.
/// Copy new `[factory]` rows into the debug panel the operator pastes.
@MainActor
final class FactoryLogMirror {
    static let shared = FactoryLogMirror()

    private var seenIDs: Set<String> = []
    private var task: Task<Void, Never>?

    func start(repository: DBRepository) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pull(repository: repository)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func pull(repository: DBRepository) async {
        let rows = (try? await repository.recentServiceLogs(limit: 200)) ?? []
        for row in rows.reversed() {
            let isFactory = row.code == "factory" || row.message.contains("[factory]")
            guard isFactory, seenIDs.insert(row.id).inserted else { continue }
            debugLog(row.message)
        }
    }
}
