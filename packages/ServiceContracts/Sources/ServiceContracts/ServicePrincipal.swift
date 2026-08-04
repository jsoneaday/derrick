import Foundation

/// Who is authorized to request work (MCP, jobs, agent wake).
public enum ServicePrincipal: Codable, Sendable, Hashable {
    case ui
    case agent(sessionID: String, agentID: String)
    case job(jobID: String)
    case webhook(source: String)
    case system

    public var logLabel: String {
        switch self {
        case .ui: return "ui"
        case .agent(let sessionID, let agentID): return "agent:\(agentID)@\(sessionID.prefix(8))"
        case .job(let jobID): return "job:\(jobID)"
        case .webhook(let source): return "webhook:\(source)"
        case .system: return "system"
        }
    }
}
