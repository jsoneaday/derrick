import DBRepository
import Foundation
import Plugin
import ServiceContracts

enum PluginHookDispatcher {
    static func runBeforeInvoke(
        plugin: PluginRow,
        version: PluginVersionRow,
        params: [String: PluginJSON],
        repository: DBRepository,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> PluginHookOutcome {
        let grants = plugin.hookGrants.filter {
            $0.event == PluginHookGrant.pluginInvokeEvent && $0.phase == .before
        }
        for grant in grants {
            switch grant.hook {
            case .openFactorySession:
                return try await openFactorySession(
                    plugin: plugin,
                    version: version,
                    params: params,
                    repository: repository,
                    logger: logger
                )
            }
        }
        return .proceed
    }

    private static func openFactorySession(
        plugin: PluginRow,
        version: PluginVersionRow,
        params: [String: PluginJSON],
        repository: DBRepository,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> PluginHookOutcome {
        let sessionID = FactorySessionID.make()
        let goal = params["goal"]?.stringValue
            ?? params["text"]?.stringValue
            ?? ""
        var draft = FactoryPackageDraft(goal: goal)
        if let reuse = params["reuse_plugin_id"]?.stringValue, !reuse.isEmpty {
            draft.reusePluginID = reuse
            draft.pluginID = reuse
        }
        let spec = (try? JSONEncoder().encode(draft)).flatMap { String(data: $0, encoding: .utf8) }
        try await repository.upsertFactorySession(
            FactorySessionRow(
                sessionID: sessionID,
                specJSON: spec,
                stage: "spec",
                pluginID: draft.reusePluginID,
                instructionPluginID: plugin.id
            )
        )
        logger("[factory] hook open_factory_session plugin=\(plugin.id) session=\(sessionID)")
        let title = draft.reusePluginID.map { "Change \($0)" } ?? "Create plugin"
        let encoded = PluginHookPresentation.encodeOpenFactory(
            PluginHookPresentation.OpenFactory(
                sessionID: sessionID,
                title: title,
                instructionPluginID: plugin.id,
                reusePluginID: draft.reusePluginID,
                goal: goal
            )
        )
        return .handled(resultJSON: encoded)
    }
}


