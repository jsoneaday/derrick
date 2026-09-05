import Foundation
import Structure

public enum PolicyUserEventFactory {
    public static func failure(
        source: PolicyEventSource,
        title: String,
        summary: String,
        detail: String? = nil,
        toolName: String? = nil,
        payloadPreview: String? = nil,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        PolicyUserEvent(
            priority: .userDecision,
            correlationId: correlationId,
            kind: .failure,
            source: source,
            title: title,
            summary: summary,
            detail: detail,
            toolName: toolName,
            payloadPreview: payloadPreview
        )
    }

    public static func approvalRequired(
        source: PolicyEventSource = .toolGovernance,
        title: String = "Approval required",
        summary: String,
        detail: String? = nil,
        toolName: String?,
        payloadPreview: String?,
        correlationId: String? = nil,
        rememberKey: String? = nil
    ) -> PolicyUserEvent {
        PolicyUserEvent(
            priority: .userDecision,
            correlationId: correlationId,
            kind: .approvalRequired,
            source: source,
            title: title,
            summary: summary,
            detail: detail,
            toolName: toolName,
            payloadPreview: payloadPreview,
            rememberKey: rememberKey
        )
    }

    public static func staticValidationDenied(
        findings: [String],
        toolName: String = "script_exec",
        scriptPreview: String? = nil,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .staticValidation,
            title: "Request blocked",
            summary: findings.first ?? "The request failed static policy checks.",
            detail: findings.joined(separator: "\n"),
            toolName: toolName,
            payloadPreview: scriptPreview,
            correlationId: correlationId
        )
    }

    public static func reviewerDenied(
        summary: String,
        concerns: [String],
        toolName: String = "script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .llmReviewer,
            title: "Request denied by security review",
            summary: summary,
            detail: concerns.isEmpty ? nil : concerns.joined(separator: "\n"),
            toolName: toolName,
            correlationId: correlationId
        )
    }

    public static func typecheckFailed(
        message: String,
        toolName: String = "script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        return failure(
            source: .system,
            title: "Swift check failed",
            summary: firstLine ?? "The Swift compiler rejected the script.",
            detail: trimmed.isEmpty ? nil : trimmed,
            toolName: toolName,
            correlationId: correlationId
        )
    }

    public static func scriptExecutionFailed(
        exitCode: Int32,
        stderr: String,
        toolName: String = "script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = Self.humanReadableScriptFailureSummary(exitCode: exitCode, stderr: trimmed)
        return failure(
            source: .system,
            title: "Script execution failed",
            summary: summary,
            detail: trimmed.isEmpty ? "exit code \(exitCode)" : "exit code \(exitCode)\n\(trimmed)",
            toolName: toolName,
            correlationId: correlationId
        )
    }

    /// Prefer a short user-facing reason; full traceback stays in `detail`.
    private static func humanReadableScriptFailureSummary(exitCode: Int32, stderr: String) -> String {
        if stderr.isEmpty {
            return "The script exited with code \(exitCode)."
        }
        let lower = stderr.lowercased()
        if lower.contains("jsondecodeerror")
            || lower.contains("decodingerror")
            || lower.contains("jsondecoder")
            || lower.contains("data corrupted") {
            return "The script expected JSON from a network response but received non-JSON (often an HTML error or block page). Check the destination URL and response."
        }
        if lower.contains("urlerror")
            || lower.contains("connection")
            || lower.contains("dns")
            || lower.contains("name resolution") {
            return "The script could not reach a network host (connection or DNS failure)."
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return "The script timed out while waiting for a network response."
        }
        // Prefer the last non-empty traceback line when it looks like an exception type.
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let lastException = lines.reversed().first(where: {
            $0.contains("Error:") || $0.contains("Exception:") || $0.hasPrefix("json.decoder")
        }) {
            let clipped = lastException.trimmingCharacters(in: .whitespaces)
            return clipped.count > 220 ? String(clipped.prefix(220)) + "…" : clipped
        }
        return String(stderr.prefix(220)) + (stderr.count > 220 ? "…" : "")
    }

    public static func scriptExecutionTimedOut(
        toolName: String = "script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .system,
            title: "Script timed out",
            summary: "The script did not finish before the timeout.",
            toolName: toolName,
            correlationId: correlationId
        )
    }

    public static func scriptExecutionContainerLeaseExceeded(
        detail: String? = nil,
        toolName: String = "script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .system,
            title: "Container time limit reached",
            summary: "The Docker container was released after the configured maximum run time so other agents are not blocked.",
            detail: detail,
            toolName: toolName,
            correlationId: correlationId
        )
    }

    public static func egressDenied(
        detail: String,
        toolName: String = "script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .egressProxy,
            title: "Network request blocked",
            summary: "The egress proxy blocked a network destination.",
            detail: detail.isEmpty ? nil : detail,
            toolName: toolName,
            correlationId: correlationId
        )
    }

    /// Soft-blacklist hit on host HTTP. This run / Always / Deny.
    public static func blacklistHitRequest(
        url: String,
        displayPattern: String,
        kind: String,
        pattern: String,
        toolName: String = "script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        PolicyUserEvent(
            priority: .userDecision,
            correlationId: correlationId,
            kind: .networkAccessRequest,
            source: .egressProxy,
            title: "Network blacklist",
            summary: "This script wants \(url) which matches blacklist \(displayPattern).",
            detail: "This run allows this invoke only. Always removes \(displayPattern) from Settings → Network blacklist. Deny stops this request.",
            toolName: toolName,
            rememberKey: "egress.blacklist.remove:\(kind):\(pattern)"
        )
    }

    public static func egressAccessRequest(
        host: String,
        toolName: String = "script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        egressAccessRequest(hosts: [host], toolName: toolName, correlationId: correlationId)
    }

    /// One decision for one or many hosts (mid-flight / preflight batching).
    public static func egressAccessRequest(
        hosts: [String],
        toolName: String = "script_exec",
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        let unique = normalizedUniqueHosts(hosts)
        if unique.isEmpty {
            return PolicyUserEvent(
                priority: .userDecision,
                correlationId: correlationId,
                kind: .networkAccessRequest,
                source: .egressProxy,
                title: "Network access",
                summary: "Allow this script to reach an unknown host?",
                detail: "Deny cancels the entire script run.",
                toolName: toolName,
                rememberKey: nil
            )
        }
        if unique.count == 1, let host = unique.first {
            let suffix = permanentSuffixLabel(for: host)
            return PolicyUserEvent(
                priority: .userDecision,
                correlationId: correlationId,
                kind: .networkAccessRequest,
                source: .egressProxy,
                title: "Network access",
                summary: "Allow *.\(suffix)?",
                detail: "Includes \(host) and every subdomain of \(suffix). Always saves “\(suffix)” for future runs.",
                toolName: toolName,
                rememberKey: "egress.suffix:\(host)"
            )
        }
        let suffixes = unique.map { permanentSuffixLabel(for: $0) }
        let uniqueSuffixes = Array(Set(suffixes)).sorted()
        let list = unique.map { "• \($0)" }.joined(separator: "\n")
        return PolicyUserEvent(
            priority: .userDecision,
            correlationId: correlationId,
            kind: .networkAccessRequest,
            source: .egressProxy,
            title: "Network access",
            summary: "Allow these domains and their subdomains?",
            detail: "Always saves: \(uniqueSuffixes.map { "*.\($0)" }.joined(separator: ", ")).",
            toolName: toolName,
            payloadPreview: list,
            rememberKey: "egress.suffix.batch:\(uniqueSuffixes.joined(separator: ","))"
        )
    }

    private static func normalizedUniqueHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in hosts {
            let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !host.isEmpty, seen.insert(host).inserted else { continue }
            ordered.append(host)
        }
        return ordered.sorted()
    }

    public static func llmProviderFailure(
        title: String,
        message: String,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .llmProvider,
            title: title,
            summary: message,
            correlationId: correlationId
        )
    }

    public static func xpcValidationFailure(
        message: String,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .xpcValidation,
            title: "Docker helper rejected request",
            summary: message,
            detail: "The privileged helper blocked a host process that is not on the allowlist.",
            correlationId: correlationId
        )
    }

    public static func jobSchedulingFailed(
        toolName: String,
        reason: String,
        detail: String? = nil,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .toolGovernance,
            title: "Could not schedule job",
            summary: reason,
            detail: detail,
            toolName: toolName,
            correlationId: correlationId
        )
    }

    public static func toolGovernanceDenied(
        toolName: String,
        reason: String,
        payloadPreview: String? = nil,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .toolGovernance,
            title: "Tool blocked by policy",
            summary: reason,
            detail: "Tool “\(toolName)” was denied by tool governance.",
            toolName: toolName,
            payloadPreview: payloadPreview,
            correlationId: correlationId
        )
    }

    public static func contentGovernanceDenied(
        reason: String,
        payloadPreview: String? = nil,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .contentGovernance,
            title: "Content blocked by policy",
            summary: reason,
            detail: "Assistant output was denied by content governance.",
            payloadPreview: payloadPreview,
            correlationId: correlationId
        )
    }

    /// Confirm sensitive assistant content: Allow once / Always / Deny (same chrome as network).
    public static func contentSensitivityAccessRequest(
        categories: [String],
        categoryIds: [String],
        payloadPreview: String? = nil,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        let list = categories.isEmpty ? "sensitive data" : categories.joined(separator: ", ")
        let key = categoryIds.sorted().joined(separator: ",")
        return PolicyUserEvent(
            priority: .userDecision,
            correlationId: correlationId,
            kind: .networkAccessRequest,
            source: .contentGovernance,
            title: "Sensitive content",
            summary: "This reply may include \(list). Allow it to be shown?",
            detail: "Deny discards this reply. Always remembers your choice for these categories in Settings.",
            toolName: nil,
            payloadPreview: payloadPreview,
            rememberKey: "content.category:\(key)"
        )
    }

    public static func usageLimitExceeded(
        dimensionTitle: String,
        currentLimit: Int,
        proposedSessionLimit: Int,
        detail: String? = nil,
        payloadPreview: String? = nil,
        dimensionKey: String? = nil,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        PolicyUserEvent(
            priority: .userDecision,
            correlationId: correlationId,
            kind: .usageLimitRequest,
            source: .usageLimits,
            title: "Usage limit reached",
            summary: "\(dimensionTitle) limit (\(currentLimit)) was reached.",
            detail: (detail.map { $0 + "\n\n" } ?? "")
                + "Raise for this session, or pick a permanent cap below (saved in Settings → Usage limits).",
            payloadPreview: payloadPreview,
            rememberKey: dimensionKey.map { "usage.limit:\($0)" }
        )
    }

    public static func usageLimitHardStop(
        dimensionTitle: String,
        currentLimit: Int,
        correlationId: String? = nil
    ) -> PolicyUserEvent {
        failure(
            source: .usageLimits,
            title: "Usage limit reached",
            summary: "\(dimensionTitle) is already at the maximum allowed (\(currentLimit)). This action will stop.",
            detail: "You cannot raise this further in-session. Lower usage or adjust Settings within the permanent cap.",
            correlationId: correlationId
        )
    }

    private static func permanentSuffixLabel(for host: String) -> String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return normalized }
        return parts.suffix(2).joined(separator: ".")
    }
}
