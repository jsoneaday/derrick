import Foundation

/// Parses connector scope cues embedded in a factory user goal.
public enum PluginFactoryScopeHints: Sendable {
    public static func isSendOnly(_ userGoal: String?) -> Bool {
        guard let userGoal, !userGoal.isEmpty else { return false }
        if userGoal.localizedCaseInsensitiveContains("Scope: send_message only") {
            return true
        }
        let ops = PluginFactoryValidationExpectations.requiredMessagingOps(from: userGoal)
        return ops == ["send_message"]
    }

    public static func isSendAndReceive(_ userGoal: String?) -> Bool {
        guard let userGoal, !userGoal.isEmpty else { return false }
        if userGoal.localizedCaseInsensitiveContains("Scope: sync_threads, send_message, and poll_inbox") {
            return true
        }
        if userGoal.localizedCaseInsensitiveContains("send_message and poll_inbox") {
            return true
        }
        let ops = Set(PluginFactoryValidationExpectations.requiredMessagingOps(from: userGoal))
        return ops.contains("poll_inbox")
            && ops.contains("send_message")
            && !isFullSync(userGoal)
    }

    public static func isFullSync(_ userGoal: String?) -> Bool {
        guard let userGoal, !userGoal.isEmpty else { return false }
        if userGoal.localizedCaseInsensitiveContains("Scope: sync_threads, poll_inbox, and send_message with pagination") {
            return true
        }
        if userGoal.localizedCaseInsensitiveContains("Fully sync") {
            return true
        }
        return false
    }

    public static func paginationGuidance(for userGoal: String?) -> String? {
        if isSendAndReceive(userGoal) {
            return """
            Send + receive scope: use single-page sync_threads and poll_inbox in tests and runtime \
            (one request_id per op, e.g. sync-1 and poll-1). Stop when the vendor cursor is empty. \
            Do NOT emit sync-2/poll-2 unless test_input_json includes fixtures for them. \
            Full channel history sync is not required for this scope.
            """
        }
        if isFullSync(userGoal) {
            return """
            Full sync scope: paginate vendor list/history APIs. Every emitted pagination request_id \
            (sync-2, poll-2, …) must have a matching http_results fixture in test_input_json.
            """
        }
        if isSendOnly(userGoal) {
            return "Send-only scope: implement send_message only."
        }
        return nil
    }

    public static func isPaginationCompletenessRejection(_ review: PluginFactoryReview) -> Bool {
        let text = ([review.summary] + review.findings.map(\.message))
            .joined(separator: " ")
            .lowercased()
        let indicators = [
            "pagination",
            "partial results",
            "next_cursor",
            "next cursor",
            "incomplete",
            "sync-2",
            "poll-2",
        ]
        return indicators.contains(where: { text.contains($0) })
    }
}
