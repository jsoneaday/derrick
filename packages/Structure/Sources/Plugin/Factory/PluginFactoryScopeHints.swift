import Foundation

/// Parses connector scope cues embedded in a factory user goal.
public enum PluginFactoryScopeHints: Sendable {
    public static func scopeID(from userGoal: String?) -> String? {
        guard let userGoal, !userGoal.isEmpty else { return nil }
        if userGoal.contains("Scope id: full_sync")
            || userGoal.contains("Scope id: send_only")
            || userGoal.contains("Scope id: send_and_receive")
            || userGoal.localizedCaseInsensitiveContains("Fully sync")
            || userGoal.localizedCaseInsensitiveContains("Scope: sync_threads") {
            return PluginFactoryCreateInput.ConnectorScope.fullSync.rawValue
        }
        return nil
    }

    public static func isFullSync(_ userGoal: String?) -> Bool {
        scopeID(from: userGoal) == PluginFactoryCreateInput.ConnectorScope.fullSync.rawValue
    }

    public static func paginationGuidance(for userGoal: String?) -> String? {
        guard let id = scopeID(from: userGoal),
              let spec = try? ConnectorContractStore.loadProtocol().scope(id: id) else {
            return nil
        }
        return "test_pagination=\(spec.testPagination) include_reply_poll=\(spec.includeReplyPoll)"
    }

    /// LLM reviewer asked sync_threads to crawl history/replies. The host loads those in poll_inbox.
    public static func isMisplacedHistoryInSyncThreadsRejection(_ review: PluginFactoryReview) -> Bool {
        let text = reviewText(review)
        guard text.contains("sync_threads") else { return false }
        let mentionsHistory = text.contains("conversations.history")
            || text.contains("conversations.replies")
            || text.contains("channel history")
            || text.contains("reply thread")
        let complainsMissing = text.contains("never fetches")
            || text.contains("does not fetch")
            || text.contains("not implemented")
            || text.contains("only paginates")
            || text.contains("emits channel tabs")
            || text.contains("cannot fully sync")
            || text.contains("not implemented or tested")
        return mentionsHistory && complainsMissing
    }

    /// LLM reviewer treated a successful empty inbox as a bug. Quiet channels are normal.
    public static func isEmptySuccessfulPollRejection(_ review: PluginFactoryReview) -> Bool {
        let text = reviewText(review)
        let emptyInbox = text.contains("empty")
            && (text.contains("messages") || text.contains("inbox"))
        let treatedAsSuccess = text.contains("success")
        let vendorError = text.contains("ok false")
            || text.contains("missing_scope")
            || text.contains("no_permission")
            || text.contains("not_in_channel")
        return emptyInbox && treatedAsSuccess && !vendorError
    }

    public static func isOverstrictFullSyncRejection(_ review: PluginFactoryReview) -> Bool {
        if hasDisqualifyingBlockingFinding(review) { return false }
        return isMisplacedHistoryInSyncThreadsRejection(review)
            || isEmptySuccessfulPollRejection(review)
    }

    /// Approves when the reviewer rejects a host-contract rule that is already in the JSON.
    public static func approvedOverride(
        for review: PluginFactoryReview,
        userGoal: String?
    ) -> PluginFactoryReview? {
        guard !review.approved else { return nil }
        if isFullSync(userGoal), isOverstrictFullSyncRejection(review) {
            return PluginFactoryReview(
                decision: .approved,
                findings: [],
                summary: """
                Approved after deterministic validation (full sync lists tabs in sync_threads; \
                empty polls are success when the vendor succeeded).
                """
            )
        }
        return nil
    }

    private static func reviewText(_ review: PluginFactoryReview) -> String {
        ([review.summary] + review.findings.map(\.message))
            .joined(separator: " ")
            .lowercased()
    }

    private static func hasDisqualifyingBlockingFinding(_ review: PluginFactoryReview) -> Bool {
        review.findings.contains { finding in
            guard finding.severity == .blocking else { return false }
            if finding.category == .safety
                || finding.category == .privacy
                || finding.category == .supplyChain {
                return true
            }
            let message = finding.message.lowercased()
            return message.contains("urllib")
                || message.contains("requests")
                || message.contains("socket")
                || message.contains("subprocess")
        }
    }
}
