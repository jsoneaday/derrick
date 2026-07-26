import Foundation

/// Product MCP tools that may be registered and invoked.
///
/// This is the **tool catalog** (what exists), not **policy** (what actions are allowed).
/// Add a case here when introducing a new first-class tool; wire registration + policy allows from `allCases`.
public enum AllowedMCPTool: String, CaseIterable, Sendable, Codable, Hashable {
    case pythonScriptExec = "python_script_exec"
    case sessionMemorySearch = "session_memory_search"

    /// Wire name used by MCP list/call and policy matchers (`tool_name`).
    public var toolName: String { rawValue }

    public var defaultDescription: String {
        switch self {
        case .pythonScriptExec:
            return "Run declared Python script in a constrained Docker container after verification."
        case .sessionMemorySearch:
            return "Search prior session memory entries with optional query and paging."
        }
    }
}
