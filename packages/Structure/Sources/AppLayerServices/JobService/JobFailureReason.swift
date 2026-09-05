import Foundation

/// Stable failure codes for jobs (persisted as `error_code`, shown in UI).
public enum JobFailureReason: String, Codable, Sendable, Hashable {
    /// Job was `running` when JobService exited (logout, crash, sleep without clean shutdown).
    case interruptedDeviceUnavailable
    /// Step body failed (tool deny, agent reject, decode error, etc.).
    case stepFailed
    /// Could not reach or bootstrap MCPService.
    case mcpUnavailable
    /// Could not reach or bootstrap AgentService.
    case agentUnavailable
    /// Invalid template / unknown step kind / empty steps.
    case invalidRecord
    /// Explicit cancel.
    case cancelled
    /// Catch-all.
    case unknown

    /// Short phrase after "Last attempt failed due to: ".
    public var displayPhrase: String {
        switch self {
        case .interruptedDeviceUnavailable:
            return "JobService stopped while this job was running (device sleep, logout, crash, or keep-alive stopped)"
        case .stepFailed:
            return "a job step failed"
        case .mcpUnavailable:
            return "MCPService was unavailable"
        case .agentUnavailable:
            return "AgentService was unavailable"
        case .invalidRecord:
            return "invalid job data"
        case .cancelled:
            return "the job was cancelled"
        case .unknown:
            return "an unknown error"
        }
    }

    /// Full user-facing line: `Last attempt failed due to: …`.
    public func lastAttemptMessage(detail: String? = nil) -> String {
        var message = "Last attempt failed due to: \(displayPhrase)"
        if let detail {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != displayPhrase {
                message += " — \(trimmed)"
            }
        }
        return message
    }

    public static func classify(_ error: Error) -> JobFailureReason {
        let text = error.localizedDescription.lowercased()
        if text.contains("mcpservice") || text.contains("mcp service") {
            return .mcpUnavailable
        }
        if text.contains("agentservice") || text.contains("agent service") {
            return .agentUnavailable
        }
        if text.contains("invalid") || text.contains("unknown step") {
            return .invalidRecord
        }
        if text.contains("cancel") {
            return .cancelled
        }
        return .stepFailed
    }
}

/// Non-terminal notes (e.g. started late after sleep). Not a failure by itself.
public enum JobStatusDetail {
    /// Human-readable note when a job runs after its scheduled `runAt`.
    public static func startedLate(scheduledAt: Date, startedAt: Date = .now) -> String {
        let late = max(0, startedAt.timeIntervalSince(scheduledAt))
        let minutes = Int(late / 60)
        let hours = minutes / 60
        let lag: String
        if hours >= 1 {
            lag = "\(hours)h \(minutes % 60)m"
        } else if minutes >= 1 {
            lag = "\(minutes)m"
        } else {
            lag = "\(Int(late))s"
        }
        return "Started \(lag) late (device was asleep or JobService was not running until now)."
    }
}
