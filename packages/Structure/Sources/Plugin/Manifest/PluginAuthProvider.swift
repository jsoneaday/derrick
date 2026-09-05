import Foundation

/// Host-owned OAuth / token provider. Secrets never enter the guest.
/// Attach only when `url.host` is in `attachHosts` and not a `tokenHosts` entry.
public struct PluginAuthProvider: Sendable, Hashable, Identifiable {
    public var id: String
    public var attachHosts: Set<String>
    public var tokenHosts: Set<String>
    /// Host rewrites the URL (Telegram bot token in the path).
    public var rewritesURL: Bool

    public init(id: String, attachHosts: Set<String>, tokenHosts: Set<String>, rewritesURL: Bool = false) {
        self.id = id
        self.attachHosts = Set(attachHosts.map { $0.lowercased() })
        self.tokenHosts = Set(tokenHosts.map { $0.lowercased() })
        self.rewritesURL = rewritesURL
    }

    public func attachDecision(host: String) -> PluginAuthAttachDecision {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if tokenHosts.contains(host) { return .denyTokenHost }
        if attachHosts.contains(host) { return .attach }
        return .denyNotAttachHost
    }

    /// Telegram-style `/bot<token>/` must not appear on the guest URL.
    public func urlContainsEmbeddedToken(_ url: URL) -> Bool {
        guard rewritesURL else { return false }
        let path = url.path
        return path.range(of: #"/bot[^/]+/"#, options: .regularExpression) != nil
            || path.range(of: #"/bot[^/]+$"#, options: .regularExpression) != nil
    }
}

public enum PluginAuthAttachDecision: String, Sendable, Hashable {
    case attach
    case denyTokenHost
    case denyNotAttachHost
}

public struct PluginAuthRef: Codable, Sendable, Hashable {
    public var name: String
    public var provider: String

    public init(name: String, provider: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64,
              name.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
            throw PluginManifestError.invalidAuthRefName(name)
        }
        guard PluginAuthRegistry.lookup(provider) != nil else {
            throw PluginManifestError.unknownAuthProvider(provider)
        }
        self.name = name
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey {
        case name, provider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let provider = try container.decode(String.self, forKey: .provider)
        try self.init(name: name, provider: provider)
    }
}

public enum PluginAuthRegistry: Sendable {
    public static let google = PluginAuthProvider(
        id: "google",
        attachHosts: [
            "gmail.googleapis.com",
            "www.googleapis.com",
        ],
        tokenHosts: [
            "oauth2.googleapis.com",
            "accounts.google.com",
        ]
    )

    public static let telegram = PluginAuthProvider(
        id: "telegram",
        attachHosts: [
            "api.telegram.org",
        ],
        tokenHosts: [],
        rewritesURL: true
    )

    public static let all: [PluginAuthProvider] = [google, telegram]

    public static func lookup(_ id: String) -> PluginAuthProvider? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == id }
    }
}
