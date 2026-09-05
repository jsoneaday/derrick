import Foundation

/// XPC / in-process timeouts for MCP effector calls.
public enum MCPToolCallTimeouts {
    /// Health checks, searchTools, and short effectors.
    public static let standardNanoseconds: UInt64 = 15_000_000_000

    /// `web.crawl`, `plugin_factory_build`, and `script_exec` (matches the fifteen-minute job tool ceiling).
    public static let longRunningNanoseconds: UInt64 = 915_000_000_000

    /// `plugin.invoke` spins up an offline Docker guest (container create + HTTP hops).
    /// Must be at least as long as `MCPServiceDockerHelperRunner` call timeout.
    public static let pluginInvokeNanoseconds: UInt64 = 120_000_000_000

    public static func nanoseconds(forToolName toolName: String) -> UInt64 {
        switch toolName {
        case "web.crawl", "plugin_factory_build", "script_exec":
            return longRunningNanoseconds
        case "plugin.invoke":
            return pluginInvokeNanoseconds
        default:
            return standardNanoseconds
        }
    }
}
