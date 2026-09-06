import Foundation
import Plugin
import Structure

/// Approves drafts that already passed deterministic factory validation.
public actor E2EHarnessReviewer: PluginFactoryReviewer {
    public init() {}

    public func review(
        draft: PluginFactoryDraft,
        directRun: PluginFactoryExecutionResult
    ) async throws -> PluginFactoryReview {
        _ = draft
        _ = directRun
        return PluginFactoryReview(
            decision: .approved,
            findings: [],
            summary: "Approved after deterministic factory validation."
        )
    }
}
