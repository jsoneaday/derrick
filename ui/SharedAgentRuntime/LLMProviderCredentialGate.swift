import Foundation
import Structure

/// Provider credential checks and API key resolution (Keychain or `.env`, per `AppSecretResolver`).
@MainActor
enum LLMProviderCredentialGate {
    /// One key per provider — the single resolution path for chat, reviewers, workers, and jobs.
    static func resolveAPIKey(
        for provider: LLMProviderChoice,
        resolver: AppSecretResolver = AppSecretResolver()
    ) -> String? {
        resolver.resolve(
            account: provider.secretAccount,
            environmentKeys: provider.apiKeyEnvironmentKeys
        )
    }

    static func resolveAPIKey(
        for model: LLMModelChoice,
        resolver: AppSecretResolver = AppSecretResolver()
    ) -> String? {
        resolveAPIKey(for: model.provider, resolver: resolver)
    }

    /// Off-main callers (AgentService, MCPService, jobs).
    static func resolveAPIKey(for provider: LLMProviderChoice) async -> String? {
        await MainActor.run {
            resolveAPIKey(for: provider)
        }
    }

    static func resolveAPIKey(for model: LLMModelChoice) async -> String? {
        await resolveAPIKey(for: model.provider)
    }

    static func hasAPIKey(for provider: LLMProviderChoice, resolver: AppSecretResolver) -> Bool {
        resolveAPIKey(for: provider, resolver: resolver) != nil
    }

    static func configuredProviders(resolver: AppSecretResolver) -> [LLMProviderChoice] {
        LLMProviderChoice.allCases.filter { hasAPIKey(for: $0, resolver: resolver) }
    }

    static func usesDotenvSecrets() -> Bool {
        DotEnvReader.usesDotenvOnly
    }

    static func configurationHint(for provider: LLMProviderChoice) -> String {
        let keys = provider.apiKeyEnvironmentKeys.joined(separator: " or ")
        if usesDotenvSecrets() {
            return "Set \(keys) in `\(DotEnvReader.repositoryRelativePath)`."
        }
        return "Add your \(provider.apiKeyName) in Settings → Credentials."
    }
}
