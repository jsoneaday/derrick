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
    case factoryBuild = "factory.build"
    case factoryWritePackage = "factory.write_package"
    case factoryReview = "factory.review"
    case factoryTest = "factory.test"
    case factoryPromote = "factory.promote"
    case factoryInstallSample = "factory.install_sample"
    case pluginInvoke = "plugin.invoke"
    case pluginList = "plugin.list"

    /// Wire name used by MCP list/call and policy matchers (`tool_name`).
    public var toolName: String { rawValue }

    public static func isScriptExec(_ name: String) -> Bool {
        name == scriptExec.rawValue
    }

    public var defaultDescription: String {
        switch self {
        case .scriptExec:
            return "Run declared JavaScript (Bun) in a constrained Docker container after verification. Use netFetch for HTTP; the host performs the request."
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
        case .factoryBuild:
            return "Start or resume this Software Factory session. Required: goal (the user's request, in their words)."
        case .factoryWritePackage:
            return "Write the plugin package (id, version, description, TypeScript handle, optional deps and fixtures). Runs static checks."
        case .factoryReview:
            return "Security-review the current factory package against its spec. Required before promote."
        case .factoryTest:
            return "Run a test of the current plugin with sample parameters. Required before install."
        case .factoryPromote:
            return "Ask the user to install the reviewed plugin. Swift hashes, grants, and enables one version. Factory cannot install by itself."
        case .factoryInstallSample:
            return "Install the shipped daily-news sample after the user approves. No auth. One public news host."
        case .pluginInvoke:
            return "Run an installed plugin's frozen handle. Pass plugin_id and optional params (JSON object → event.params). Same hop loop as script_exec (netFetch → host HTTP)."
        case .pluginList:
            return "List installed plugins (id, version, description, enabled)."
        }
    }
}
