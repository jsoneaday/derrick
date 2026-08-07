import Foundation

/// Stable XPC / bundle identifiers for Derrick background services.
public enum DerrickServiceID: String, Codable, Sendable, CaseIterable, Hashable {
    case ui = "derrick.ui"
    case agent = "derrick.ui.AgentService"
    case job = "derrick.ui.JobService"
    case mcp = "derrick.ui.MCPService"
    case webhook = "derrick.ui.WebhookService"
    case dockerHelper = "derrick.ui.DockerRunnerHelper"
    /// Login LaunchAgent that keeps JobService connected for the user session.
    case jobKeepAlive = "derrick.ui.JobKeepAlive"

    /// NSXPC `serviceName` for embedded XPC helpers.
    public var xpcServiceName: String { rawValue }

    public var shortName: String {
        switch self {
        case .ui: return "ui"
        case .agent: return "agent"
        case .job: return "job"
        case .mcp: return "mcp"
        case .webhook: return "webhook"
        case .dockerHelper: return "docker"
        case .jobKeepAlive: return "job-keepalive"
        }
    }
}

/// Wire protocol version for health negotiation.
public enum ServiceProtocolVersion: Int, Codable, Sendable {
    case v1 = 1
}
