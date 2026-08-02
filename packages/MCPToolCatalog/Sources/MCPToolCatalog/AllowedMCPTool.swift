import Foundation

/// Product MCP tools that may be registered and invoked.
///
/// This is the **tool catalog** (what exists), not **policy** (what actions are allowed).
/// Add a case here when introducing a new first-class tool; wire registration + policy allows from `allCases`.
public enum AllowedMCPTool: String, CaseIterable, Sendable, Codable, Hashable {
    case pythonScriptExec = "python_script_exec"
    case sessionMemorySearch = "session_memory_search"
    case agentsSpawn = "agents_spawn"
    case agentsCompleteTask = "agents_complete_task"
    case agentsList = "agents_list"
    case agentsSend = "agents_send"
    case agentsCancel = "agents_cancel"

    /// Wire name used by MCP list/call and policy matchers (`tool_name`).
    public var toolName: String { rawValue }

    public var defaultDescription: String {
        switch self {
        case .pythonScriptExec:
            return "Run declared Python script in a constrained Docker container after verification."
        case .sessionMemorySearch:
            return "Search prior session memory entries with optional query and paging."
        case .agentsSpawn:
            return "Spawn a child worker agent, assign a task, and wait for its result (hierarchical multi-agent)."
        case .agentsCompleteTask:
            return "Worker reports task completion result back to its parent."
        case .agentsList:
            return "List agents in the current session (or only children of the caller)."
        case .agentsSend:
            return "Send a message to a parent or child agent only (no peer messaging)."
        case .agentsCancel:
            return "Cancel a child agent (or self) in the current session."
        }
    }
}
