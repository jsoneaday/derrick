import Foundation

/// Shared runtime is compiled into services that do not include the app UI.
/// The app installs `handler` so a spend limit can use the create-plugin modal.
/// Services with no handler fall back to the global failure reporter.
enum ModelProviderLimitRouting {
    nonisolated(unsafe) static var handler: (@Sendable (String) -> Void)?

    @MainActor
    static func report(raw: String) {
        if let handler {
            handler(raw)
            return
        }
        LLMFailureReporter.shared.report(.outOfCredits(provider: "your model provider"))
    }
}
