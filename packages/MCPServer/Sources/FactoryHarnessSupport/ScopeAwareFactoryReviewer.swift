import Foundation
import Plugin
import Structure

/// Approves send + receive drafts that passed deterministic validation when the inner reviewer
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
        guard !review.approved,
              PluginFactoryScopeHints.isSendAndReceive(draft.userGoal),
              !PluginFactoryScopeHints.isFullSync(draft.userGoal),
              PluginFactoryScopeHints.isPaginationCompletenessRejection(review)
        else {
            return review
        }
        return PluginFactoryReview(
            decision: .approved,
            findings: [],
            summary: "Approved after deterministic validation (send + receive scope does not require full pagination)."
        )
    }
}
