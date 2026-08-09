import Foundation

/// Formats persisted job failure metadata for notifications and the result modal.
public enum JobFailureDisplay: Sendable {
    /// Extracts the concrete detail from `JobFailureReason.lastAttemptMessage` output.
    public static func technicalDetail(from lastAttemptMessage: String) -> String? {
        let trimmed = lastAttemptMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let dash = trimmed.range(of: " — ", options: .backwards) {
            let detail = String(trimmed[dash.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? nil : detail
        }
        let prefix = "Last attempt failed due to: "
        if trimmed.hasPrefix(prefix) {
            let remainder = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty || remainder == JobFailureReason.stepFailed.displayPhrase {
                return nil
            }
            return remainder
        }
        return trimmed
    }

    /// Detail suitable for the modal footer — replaces generic placeholders with clearer copy.
    public static func userFacingDetail(
        from technicalDetail: String?,
        failureCode: String? = nil
    ) -> String? {
        let raw = technicalDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty, !isLowValueDetail(raw) {
            return raw
        }
        return fallbackMessage(for: failureCode)
    }

    /// User-facing body: agent summary plus technical detail when it adds information.
    public static func composePresentation(
        responseText: String,
        failureDetail: String?,
        failureCode: String? = nil
    ) -> String {
        let summary = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDetail = failureDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayDetail = userFacingDetail(from: rawDetail, failureCode: failureCode) else {
            return summary
        }
        if summary.localizedCaseInsensitiveContains(displayDetail) {
            return summary
        }
        if !summary.isEmpty,
           summaryAlreadyExplainsFailure(summary),
           rawDetail.map(isLowValueDetail) != false || rawDetail == nil || rawDetail?.isEmpty == true {
            return summary
        }
        if summary.isEmpty {
            return "The scheduled job failed.\n\n**What went wrong:** \(displayDetail)"
        }
        return "\(summary)\n\n**What went wrong:** \(displayDetail)"
    }

    // MARK: - Private

    private static func isLowValueDetail(_ detail: String) -> Bool {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        if JobFailureReason(rawValue: normalized) != nil { return true }
        if normalized == JobFailureReason.stepFailed.displayPhrase.lowercased() { return true }
        if normalized == JobFailureReason.unknown.displayPhrase.lowercased() { return true }
        let genericPhrases: Set<String> = [
            "something went wrong",
            "an unknown error",
            "a job step failed",
            "the job step failed",
            "step failed",
            "stepfailed",
            "unknown",
            "error",
            "failed",
            "failure",
        ]
        return genericPhrases.contains(normalized)
    }

    private static func summaryAlreadyExplainsFailure(_ summary: String) -> Bool {
        let lower = summary.lowercased()
        return lower.contains("failed")
            || lower.contains("did not complete")
            || lower.contains("stepfailed")
            || lower.contains("step failed")
            || lower.contains("without further details")
    }

    private static func fallbackMessage(for failureCode: String?) -> String? {
        guard let code = failureCode.flatMap({ JobFailureReason(rawValue: $0) }) else {
            return defaultFallback
        }
        switch code {
        case .stepFailed:
            return """
            The scheduled task failed during execution. No specific error details were captured — \
            try running it again or simplifying what the job does.
            """
        case .interruptedDeviceUnavailable:
            return JobFailureReason.interruptedDeviceUnavailable.displayPhrase
        case .mcpUnavailable:
            return "The job could not run because MCPService was unavailable. Try again after reopening Derrick."
        case .agentUnavailable:
            return "The job could not run because AgentService was unavailable. Try again after reopening Derrick."
        case .invalidRecord:
            return "The job could not run because its saved configuration was invalid."
        case .cancelled:
            return "The job was cancelled before it could finish."
        case .unknown:
            return defaultFallback
        }
    }

    private static let defaultFallback =
        "The scheduled task did not complete successfully. No additional error details were recorded."
}
