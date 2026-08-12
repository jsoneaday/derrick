import Foundation

/// Optional in-process implementations installed by derrickd so SharedAgentRuntime
/// clients can skip XPC when Agent/Job/MCP share the daemon process.
public enum InProcessServiceBridges: Sendable {
    public typealias CallTool = @Sendable (MCPToolCallRequest) async throws -> MCPToolCallResultDTO
    public typealias SearchTools = @Sendable (ServicePrincipal, String) async throws -> MCPToolSearchResultDTO
    public typealias EnsureReady = @Sendable () async throws -> Void
    /// Job python network banner preflight (toolName, argumentsJSON, jobID).
    public typealias JobNetworkPreflight =
        @Sendable (_ toolName: String, _ argumentsJSON: String, _ jobID: String) async throws -> Void
    public typealias PushEgressAllowlist = @Sendable (_ suffixes: [String]) async -> Void
    public typealias GrantEgressSessionHosts = @Sendable (_ hosts: [String]) async -> Void

    nonisolated(unsafe) public static var mcpCallTool: CallTool?
    nonisolated(unsafe) public static var mcpSearchTools: SearchTools?
    nonisolated(unsafe) public static var mcpEnsureReady: EnsureReady?

    /// Opaque local JobServiceXPC object (JobServiceExportedObject) when running in derrickd.
    nonisolated(unsafe) public static var jobLocalProxy: AnyObject?

    /// Installed by derrickd: banner-based network approval before scheduled python jobs.
    nonisolated(unsafe) public static var jobNetworkPreflight: JobNetworkPreflight?

    nonisolated(unsafe) public static var pushEgressAllowlist: PushEgressAllowlist?
    nonisolated(unsafe) public static var grantEgressSessionHosts: GrantEgressSessionHosts?
}
