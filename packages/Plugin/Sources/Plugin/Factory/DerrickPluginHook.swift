import Foundation

/// Host-owned hook kinds. Plugins do not invent new kinds.
public enum DerrickPluginHook: String, Codable, Sendable, Hashable, CaseIterable {
    case openFactorySession = "open_factory_session"
}

public enum PluginHookPhase: String, Codable, Sendable, Hashable {
    case before
    case after
}

/// A granted hook: which event, when, and which kind.
public struct PluginHookGrant: Codable, Sendable, Hashable {
    public var event: String
    public var phase: PluginHookPhase
    public var hook: DerrickPluginHook

    public init(
        event: String = PluginHookGrant.pluginInvokeEvent,
        phase: PluginHookPhase = .before,
        hook: DerrickPluginHook
    ) {
        self.event = event
        self.phase = phase
        self.hook = hook
    }

    public static let pluginInvokeEvent = "plugin.invoke"

    public static func decodeList(_ raw: String) -> [PluginHookGrant] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty, trimmed != "[]" else {
            return []
        }
        if let grants = try? JSONDecoder().decode([PluginHookGrant].self, from: data) {
            return grants
        }
        if let names = try? JSONDecoder().decode([String].self, from: data) {
            return names.compactMap { name in
                guard let hook = DerrickPluginHook(rawValue: name) else { return nil }
                return PluginHookGrant(hook: hook)
            }
        }
        return []
    }

    public static func encodeList(_ grants: [PluginHookGrant]) -> String {
        let data = (try? JSONEncoder().encode(grants)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum PluginHookOutcome: Sendable {
    case handled(resultJSON: String)
    case proceed
}
