import Foundation

public enum PluginGuestLanguage: String, Sendable, Equatable, Codable {
    case python
}

/// Parsed `app.derrick/runtime.json` from an approved factory release.
public struct PluginFactoryRuntime: Sendable, Equatable {
    public let language: PluginGuestLanguage
    public let entrypoint: String

    public init(language: PluginGuestLanguage = .python, entrypoint: String) {
        self.language = language
        self.entrypoint = entrypoint
    }

    public static func decode(from json: String) -> PluginFactoryRuntime? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entrypoint = object["entrypoint"] as? String,
              !entrypoint.isEmpty
        else {
            return nil
        }
        return PluginFactoryRuntime(entrypoint: entrypoint)
    }
}

public extension PluginFactoryRelease {
    /// All approved releases run as Python guests.
    var guestLanguage: PluginGuestLanguage { .python }
}
