import DBRepository
import Foundation
import MCPServer
import Plugin
import PolicyUserInteraction

/// Host-owned plugin secrets. Material is stored as config; never logged.
actor PluginSecretStore {
    static let shared = PluginSecretStore()

    private static let username = "ui"
    private static let password = "ui"

    private init() {}

    func hasSecret(provider: String, repository: DBRepository) async -> Bool {
        let material = await secretMaterial(provider: provider, repository: repository)
        return material?.isEmpty == false
    }

    func secretMaterial(provider: String, repository: DBRepository) async -> String? {
        let key = materialKey(provider)
        guard let raw = try? await repository.loadConfig(
            key: key,
            username: Self.username,
            password: Self.password
        ) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(provider: String, material: String, repository: DBRepository) async throws {
        let trimmed = material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PluginAuthRegistry.lookup(provider) != nil else {
            throw PluginSecretStoreError.unknownProvider(provider)
        }
        if trimmed.isEmpty {
            try await repository.saveConfig(
                key: materialKey(provider),
                value: "",
                username: Self.username,
                password: Self.password
            )
            return
        }
        try await repository.saveConfig(
            key: materialKey(provider),
            value: trimmed,
            username: Self.username,
            password: Self.password
        )
        let meta = PluginSecretRecord(provider: provider)
        if let data = try? JSONEncoder().encode(meta),
           let json = String(data: data, encoding: .utf8) {
            try await repository.saveConfig(
                key: metaKey(provider),
                value: json,
                username: Self.username,
                password: Self.password
            )
        }
    }

    func listedProviders(repository: DBRepository) async -> [String] {
        var present: [String] = []
        for provider in PluginAuthRegistry.all {
            if await hasSecret(provider: provider.id, repository: repository) {
                present.append(provider.id)
            }
        }
        return present
    }

    private func materialKey(_ provider: String) -> String {
        "plugin.secret.material.\(provider.lowercased())"
    }

    private func metaKey(_ provider: String) -> String {
        "plugin.secret.meta.\(provider.lowercased())"
    }
}

enum PluginSecretStoreError: Error, LocalizedError {
    case unknownProvider(String)

    var errorDescription: String? {
        switch self {
        case .unknownProvider(let id):
            return "Unknown secret provider: \(id)."
        }
    }
}

struct PluginHostSecretAttacher: HostHTTPSecretAttacher {
    let repository: DBRepository

    func apply(url: URL) async -> (url: URL, headers: [String: String]) {
        guard let pluginID = MCPServiceCallContext.shared.pluginID else {
            return (url, [:])
        }
        let grants = (try? await repository.listPluginGrants(pluginID: pluginID)) ?? []
        var providers: [String] = []
        for grant in grants {
            if let data = grant.authRefsJSON.data(using: .utf8),
               let refs = try? JSONDecoder().decode([PluginAuthRef].self, from: data) {
                providers.append(contentsOf: refs.map(\.provider))
            }
        }
        for name in Set(providers) {
            guard let provider = PluginAuthRegistry.lookup(name),
                  let material = await PluginSecretStore.shared.secretMaterial(
                    provider: name,
                    repository: repository
                  ) else { continue }
            if let attached = PluginSecretAttach.apply(url: url, provider: provider, secretMaterial: material) {
                return attached
            }
        }
        return (url, [:])
    }
}

struct FactoryPluginHopHandler: PluginHopHandler {
    let pluginID: String
    let repository: DBRepository

    func handleUIPresent(payload: [String: PluginJSON]) async -> PluginHopEvent? {
        _ = payload
        return nil
    }

    func handleSecretRequest(payload: [String: PluginJSON]) async -> PluginHopEvent? {
        let provider = payload["provider"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard PluginAuthRegistry.lookup(provider) != nil else { return nil }
        let event = PolicyUserEventFactory.pluginSecretGrant(pluginID: pluginID, provider: provider)
        let decision = await PolicyDecisionRouting.requestDecision(event)
        switch decision {
        case .approved, .approvedOnce, .approvedPermanently:
            guard await PluginSecretStore.shared.hasSecret(provider: provider, repository: repository) else {
                return nil
            }
            try? await appendGrant(provider: provider)
            return PluginHopEvent(
                kind: .grantReady,
                params: ["provider": .string(provider)]
            )
        default:
            return nil
        }
    }

    private func appendGrant(provider: String) async throws {
        let plugin = try await repository.plugin(id: pluginID)
        guard let versionID = plugin?.currentVersionID else { return }
        var refs: [PluginAuthRef] = []
        if let existing = try await repository.listPluginGrants(pluginID: pluginID).first,
           let data = existing.authRefsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([PluginAuthRef].self, from: data) {
            refs = decoded
        }
        if refs.contains(where: { $0.provider == provider }) { return }
        refs.append(try PluginAuthRef(name: provider, provider: provider))
        let data = try JSONEncoder().encode(refs)
        try await repository.upsertPluginGrant(
            PluginGrantRow(
                pluginID: pluginID,
                versionID: versionID,
                authRefsJSON: String(decoding: data, as: UTF8.self)
            )
        )
    }
}
