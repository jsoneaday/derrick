import Foundation
import Structure

/// Routes a model-provider spend or rate limit.
///
/// A run that already has a modal can register and receive the failure.
/// With no run modal, the global policy failure modal is used.
@MainActor
final class ModelProviderLimitCenter {
    static let shared = ModelProviderLimitCenter()

    weak var runModal: PluginCreationController?

    func report(raw: String) {
        guard ModelProviderLimit.matches(raw) else { return }
        if let runModal, runModal.injectProviderLimit(raw: raw) {
            return
        }
        LLMFailureReporter.shared.report(.outOfCredits(provider: "your model provider"))
    }
}
