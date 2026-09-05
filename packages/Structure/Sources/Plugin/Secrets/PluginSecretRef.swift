import Foundation

/// Host-owned secret material. Never placed on the guest event.
public struct PluginSecretRecord: Codable, Sendable, Equatable {
    public var provider: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(provider: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.provider = provider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Apply a granted secret to a host HTTP request. Secrets stay in Swift.
public enum PluginSecretAttach {
    public static func apply(
        url: URL,
        provider: PluginAuthProvider,
        secretMaterial: String
    ) -> (url: URL, headers: [String: String])? {
        let host = (url.host ?? "").lowercased()
        switch provider.attachDecision(host: host) {
        case .attach:
            break
        case .denyTokenHost, .denyNotAttachHost:
            return nil
        }
        if provider.rewritesURL {
            return rewriteTelegram(url: url, token: secretMaterial)
        }
        return (url, ["Authorization": "Bearer \(secretMaterial)"])
    }

    private static func rewriteTelegram(url: URL, token: String) -> (url: URL, headers: [String: String])? {
        guard !providerTokenAlreadyInURL(url) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.path ?? url.path
        if path.hasPrefix("/bot") {
            return nil
        }
        let trimmedPath = path.hasPrefix("/") ? path : "/" + path
        components?.path = "/bot\(token)\(trimmedPath)"
        guard let rewritten = components?.url else { return nil }
        return (rewritten, [:])
    }

    private static func providerTokenAlreadyInURL(_ url: URL) -> Bool {
        PluginAuthRegistry.telegram.urlContainsEmbeddedToken(url)
    }
}
