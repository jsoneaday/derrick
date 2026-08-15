import Foundation

/// Who is authorized to request work (MCP, jobs, agent wake).
public enum ServicePrincipal: Codable, Sendable, Hashable {
    case ui
    case agent(sessionID: String, agentID: String)
    case job(jobID: String)
    case webhook(source: String)
    case system
    /// Installed plugin version the host is acting for (grants, schedules, logs).
    case plugin(pluginID: String, version: String)

    public var logLabel: String {
        switch self {
        case .ui: return "ui"
        case .agent(let sessionID, let agentID): return "agent:\(agentID)@\(sessionID.prefix(8))"
        case .job(let jobID): return "job:\(jobID)"
        case .webhook(let source): return "webhook:\(source)"
        case .system: return "system"
        case .plugin(let pluginID, let version): return "plugin:\(pluginID)@\(version)"
        }
    }
}
