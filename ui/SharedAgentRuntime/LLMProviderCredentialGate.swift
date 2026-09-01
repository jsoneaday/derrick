import Foundation
import ServiceContracts

/// Whether an LLM provider has a usable API key (Keychain or `.env`, per `AppSecretResolver`).
@MainActor
enum LLMProviderCredentialGate {
    static func hasAPIKey(for provider: LLMProviderChoice, resolver: AppSecretResolver) -> Bool {
        resolver.resolve(
            account: provider.secretAccount,
            environmentKeys: provider.apiKeyEnvironmentKeys
        ) != nil
    }

    static func configuredProviders(resolver: AppSecretResolver) -> [LLMProviderChoice] {
        LLMProviderChoice.allCases.filter { hasAPIKey(for: $0, resolver: resolver) }
    }

    static func usesDotenvSecrets() -> Bool {
        PluginSecretResolver.usesDotenvOnly
    }

    static func configurationHint(for provider: LLMProviderChoice) -> String {
        let keys = provider.apiKeyEnvironmentKeys.joined(separator: " or ")
        if usesDotenvSecrets() {
            return "Set \(keys) in `\(DotEnvReader.repositoryRelativePath)`."
        }
        return "Save your key to Keychain account `\(provider.secretAccount)`, or set \(keys) in the environment."
    }
}
