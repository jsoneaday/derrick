import Foundation

/// Product MCP tools that may be registered and invoked.
///
/// This is the **tool catalog** (what exists), not **policy** (what actions are allowed).
/// Add a case here when introducing a new first-class tool; wire registration + policy allows from `allCases`.
public enum AllowedMCPTool: String, CaseIterable, Sendable, Codable, Hashable {
    case scriptExec = "script_exec"
    case sessionMemorySearch = "session_memory_search"
    case agentsSpawn = "agents_spawn"
    case agentsCompleteTask = "agents_complete_task"
    case agentsList = "agents_list"
    case agentsSend = "agents_send"
    case agentsCancel = "agents_cancel"
    /// One-shot durable job (optional delay). Local orchestration → JobService.
    case jobsCreate = "jobs_create"
    /// Recurring or one-shot schedule template. Local orchestration → JobService.
    case jobsScheduleCreate = "jobs_schedule_create"
    /// Starts one bounded plugin-factory build from a user's goal.
    case pluginFactoryBuild = "plugin_factory_build"
    /// Lists approved compiled plugin releases.
    case pluginList = "plugin.list"
    /// Runs one approved compiled plugin release.
    case pluginInvoke = "plugin.invoke"
    /// Crawls a bounded same-origin website in an isolated Swift container.
    case webCrawl = "web.crawl"
    /// Extracts or converts attached chat files in an isolated Swift container.
    case filesExtract = "files.extract"

    /// Wire name used by MCP list/call and policy matchers (`tool_name`).
    public var toolName: String { rawValue }

    public static func isScriptExec(_ name: String) -> Bool {
        name == scriptExec.rawValue
    }

    public static func isHostDiscoveryTool(_ name: String) -> Bool {
        name == "tool_search" || name == "tool" || name == "tool_batch"
    }

    public var defaultDescription: String {
        switch self {
        case .scriptExec:
            return "Run declared standalone Swift in a constrained Docker container after verification. Emit HTTP request envelopes; the host performs the request."
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
        case .jobsCreate:
            return "Create a one-shot background job (optional delay). Freezes a tool call; optional wake of this agent after the tool runs."
        case .jobsScheduleCreate:
            return "Create a recurring or one-shot schedule that spawns job runs (interval or once). Freezes a tool template; optional wake after each fire."
        case .pluginFactoryBuild:
            return "Translate a user goal into an Agent Plugin draft, test it, independently review it, compile it with Swift, and verify its release hash."
        case .pluginList:
            return "List approved compiled Agent Plugin releases."
        case .pluginInvoke:
            return "Run one approved compiled Agent Plugin by id with a JSON input object."
        case .webCrawl:
            return "Crawl a bounded same-origin website in an isolated Swift container and return structured page summaries."
        case .filesExtract:
            return "Extract text or convert attached chat files (PDF, DOCX, XLSX, CSV, HTML) in an isolated Swift container. Call this tool directly; do not submit it through jobs_create."
        }
    }
}
