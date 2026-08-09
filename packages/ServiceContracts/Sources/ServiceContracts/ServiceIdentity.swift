import Foundation

/// Stable XPC / bundle identifiers for Derrick background services.
public enum DerrickServiceID: String, Codable, Sendable, CaseIterable, Hashable {
    case ui = "derrick.ui"
    /// Headless session backend (LoginAgent). Sole notification poster; hosts agent/jobs/MCP in-process.
    case daemon = "derrick.ui.Daemon"
    case agent = "derrick.ui.AgentService"
    case job = "derrick.ui.JobService"
    case mcp = "derrick.ui.MCPService"
    case webhook = "derrick.ui.WebhookService"
    case dockerHelper = "derrick.ui.DockerRunnerHelper"
    /// Legacy keep-alive; superseded by `daemon`.
    case jobKeepAlive = "derrick.ui.JobKeepAlive"

    /// App Group used for shared DB and sandboxed Mach lookup of the daemon.
    public static let appGroupID = "VUSK4B2YKQ.derrick.shared"

    /// NSXPC `serviceName` / Mach service name for embedded XPC services.
    public var xpcServiceName: String { rawValue }

    /// LaunchAgent `MachServices` / `NSXPCConnection(machServiceName:)`.
    /// Sandboxed UI may only look up names that are an immediate child of an app group.
    public var machServiceName: String {
        switch self {
        case .daemon:
            return "\(Self.appGroupID).daemon"
        default:
            return rawValue
        }
    }

    public var shortName: String {
        switch self {
        case .ui: return "ui"
        case .daemon: return "daemon"
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
