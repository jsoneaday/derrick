import Foundation
import Plugin
import Structure

/// Approves full-sync drafts that passed deterministic validation when the inner reviewer
/// rejects host-contract nits already encoded in connector-contract.json.
/// rejects only for pagination completeness (not required for that scope).
public struct ScopeAwareFactoryReviewer: PluginFactoryReviewer {
    private let inner: any PluginFactoryReviewer

    public init(inner: any PluginFactoryReviewer) {
        self.inner = inner
    }

    public func review(
        draft: PluginFactoryDraft,
        directRun: PluginFactoryExecutionResult
    ) async throws -> PluginFactoryReview {
        let review = try await inner.review(draft: draft, directRun: directRun)
        if let override = PluginFactoryScopeHints.approvedOverride(
            for: review,
            userGoal: draft.userGoal
        ) {
            return override
        }
        return review
    }
}
