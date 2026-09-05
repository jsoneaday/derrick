import Foundation

public enum JobServiceClientError: Error, LocalizedError, Sendable {
    case unavailable
    case bootstrapFailed(String)
    case requestFailed(String)
    case timeout
    case peerEndpointMissing
    case meshUnverified(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "JobService is unavailable."
        case .bootstrapFailed(let m): return "JobService bootstrap failed: \(m)"
        case .requestFailed(let m): return "JobService request failed: \(m)"
        case .timeout: return "JobService XPC call timed out."
        case .peerEndpointMissing:
            return "JobService peer endpoint not installed (UI handoff required for AgentService)."
        case .meshUnverified(let m):
            return "Agent→JobService mesh failed verification: \(m)"
        }
    }
}

/// Port for placing durable job orders (handlers depend on this, not a concrete client).
public protocol JobOrderPlacing: Sendable {
    func createJob(_ request: CreateJobRequest) async throws -> JobRecord
    func createSchedule(_ request: CreateScheduleRequest) async throws -> JobScheduleRecord
}

/// Helpers for inspecting job tool arguments (network hosts, script flags).
public enum JobOrderPreflight {
    public static func scriptAllowNetwork(toolArgumentsJSON: String) -> Bool {
        guard let data = toolArgumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let allow = object["allow_network"] as? Bool { return allow }
        if let allow = object["allow_network"] as? Int { return allow != 0 }
        if let allow = object["allow_network"] as? String {
            let lowered = allow.lowercased()
            return lowered == "true" || lowered == "1"
        }
        return false
    }

    public static func scriptSource(from toolArgumentsJSON: String) -> String {
        guard let data = toolArgumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let script = object["script"] as? String else {
            return ""
        }
        return script
    }

    public static func extractNetworkHosts(script: String) -> [String] {
        EgressHostExtractor.extractHosts(from: script)
    }

    public static func webCrawlStartHost(toolArgumentsJSON: String) -> String? {
        guard let data = toolArgumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = object["start_url"] as? String,
              let url = URL(string: rawURL),
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty
        else {
            return nil
        }
        return host
    }
}

public enum JobNetworkPreflightError: Error, LocalizedError, Sendable {
    case denied(host: String, actor: String?)
    case hardBlocked(host: String)

    public var errorDescription: String? {
        switch self {
        case .denied(let host, let actor):
            return "Network access to \(host) was not approved (\(actor ?? "user"))."
        case .hardBlocked(let host):
            return "Network access to \(host) is permanently blocked."
        }
    }
}
