import Foundation

/// Chooses the credential a running bot or app sends on each HTTP call.
///
/// Vendor docs often list OAuth client id/secret for installing an app, and a
/// separate token or API key for calling the API. Derrick plugins call the API,
/// so the token or key wins when both are documented. No vendor-specific table.
enum ConnectorAuthPreference: Sendable {
    static func preferringCallCredential(
        _ discovery: ConnectorAuthDiscovery
    ) -> ConnectorAuthDiscovery {
        let callSecrets = discovery.secrets.filter(isCallCredential)
        if !callSecrets.isEmpty {
            return rewritten(
                discovery,
                scheme: scheme(for: callSecrets, notes: notes(discovery)),
                secrets: callSecrets
            )
        }

        if let synthesized = synthesizedCallSecret(from: notes(discovery)) {
            return rewritten(
                discovery,
                scheme: scheme(for: [synthesized], notes: notes(discovery)),
                secrets: [synthesized]
            )
        }

        // Derrick cannot run an OAuth install dance. Ask for a call token instead.
        // Use `bot_token` so host prompts, Keychain slots, and connector runtime agree
        // (daemon/ingress look for bot_token first; api_token alone used to look "missing").
        if discovery.authScheme == .oauth || discovery.secrets.contains(where: isInstallCredential) {
            if let fallback = try? PluginSecretField(
                id: "bot_token",
                label: "API token or bot token",
                kind: .token
            ) {
                return rewritten(discovery, scheme: .botToken, secrets: [fallback])
            }
        }
        return discovery
    }

    private static func rewritten(
        _ discovery: ConnectorAuthDiscovery,
        scheme: ConnectorAuthScheme,
        secrets: [PluginSecretField]
    ) -> ConnectorAuthDiscovery {
        ConnectorAuthDiscovery(
            authScheme: scheme,
            secrets: secrets,
            permissions: discovery.permissions,
            setupHint: discovery.setupHint,
            crawlSummary: discovery.crawlSummary
        )
    }

    private static func notes(_ discovery: ConnectorAuthDiscovery) -> String {
        "\(discovery.setupHint ?? "")\n\(discovery.crawlSummary ?? "")"
            .lowercased()
    }

    private static func blob(for secret: PluginSecretField) -> String {
        "\(secret.id) \(secret.label)".lowercased()
    }

    private static func isInstallCredential(_ secret: PluginSecretField) -> Bool {
        let text = blob(for: secret)
        let markers = [
            "client_id", "client id", "clientid",
            "client_secret", "client secret", "clientsecret",
            "consumer_key", "consumer key",
            "consumer_secret", "consumer secret",
            "oauth_client", "oauth client",
        ]
        return markers.contains { text.contains($0) }
    }

    private static func isCallCredential(_ secret: PluginSecretField) -> Bool {
        if isInstallCredential(secret) { return false }
        let text = blob(for: secret)
        if secret.kind == .apiKey { return true }
        let markers = [
            "bot_token", "bot token",
            "api_key", "api key",
            "api_token", "api token",
            "access_token", "access token",
            "bearer",
            "app_token", "app token",
            "personal_access", "personal access",
        ]
        if markers.contains(where: { text.contains($0) }) { return true }
        if secret.kind == .token, text.contains("token") { return true }
        return false
    }

    private static func synthesizedCallSecret(from notes: String) -> PluginSecretField? {
        if notes.contains("bot token") || notes.contains("bot user oauth token") {
            return try? PluginSecretField(id: "bot_token", label: "Bot token", kind: .token)
        }
        if notes.contains("api key") || notes.contains("x-api-key") {
            return try? PluginSecretField(id: "api_key", label: "API key", kind: .apiKey)
        }
        if notes.contains("api token") || notes.contains("personal access token")
            || notes.contains("bearer token") || notes.contains("app token")
            || notes.contains("authorization: bearer") {
            return try? PluginSecretField(id: "access_token", label: "Access token", kind: .token)
        }
        return nil
    }

    private static func scheme(
        for secrets: [PluginSecretField],
        notes: String
    ) -> ConnectorAuthScheme {
        let blob = (secrets.map { "\($0.id) \($0.label)" }.joined(separator: " ") + " " + notes)
            .lowercased()
        if blob.contains("bot token") || blob.contains("bot_token") {
            return .botToken
        }
        if secrets.contains(where: { $0.kind == .apiKey }) || blob.contains("api key") {
            return .apiKey
        }
        if secrets.contains(where: { $0.kind == .token }) {
            return .botToken
        }
        return .apiKey
    }
}
