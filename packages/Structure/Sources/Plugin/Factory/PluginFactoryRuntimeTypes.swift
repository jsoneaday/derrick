import Foundation

public enum PluginGuestLanguage: String, Sendable, Equatable, Codable {
    case go
}

/// Parsed `app.derrick/runtime.json` from an approved factory release.
public struct PluginFactoryRuntime: Sendable, Equatable {
    public let language: PluginGuestLanguage
    public let entrypoint: String

    public init(language: PluginGuestLanguage = .go, entrypoint: String) {
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
        let languageRaw = (object["language"] as? String) ?? PluginGuestLanguage.go.rawValue
        let language = PluginGuestLanguage(rawValue: languageRaw) ?? .go
        return PluginFactoryRuntime(language: language, entrypoint: entrypoint)
    }

    /// Package-relative guest source path used when hashing and verifying releases.
    public static func guestSourcePackagePath(
        runtimeJSON: String,
        manifestJSON: String,
        defaultPath: String = "app.derrick/plugin.go"
    ) -> String {
        if let runtime = decode(from: runtimeJSON) {
            return normalizePackageRelativePath(runtime.entrypoint)
        }
        if let data = manifestJSON.data(using: .utf8),
           let manifest = try? AgentPluginManifest.decode(data),
           let entrypoint = manifest.derrick?.entrypoint {
            return normalizePackageRelativePath(entrypoint)
        }
        return defaultPath
    }

    private static func normalizePackageRelativePath(_ entrypoint: String) -> String {
        var path = entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("./") {
            path = String(path.dropFirst(2))
        }
        while path.hasPrefix("/") {
            path = String(path.dropFirst())
        }
        return path
    }
}
