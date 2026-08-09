import Foundation

/// Optional in-process implementations installed by derrickd so SharedAgentRuntime
/// clients can skip XPC when Agent/Job/MCP share the daemon process.
public enum InProcessServiceBridges: Sendable {
    public typealias CallTool = @Sendable (MCPToolCallRequest) async throws -> MCPToolCallResultDTO
    public typealias SearchTools = @Sendable (ServicePrincipal, String) async throws -> MCPToolSearchResultDTO
    public typealias EnsureReady = @Sendable () async throws -> Void

    nonisolated(unsafe) public static var mcpCallTool: CallTool?
    nonisolated(unsafe) public static var mcpSearchTools: SearchTools?
    nonisolated(unsafe) public static var mcpEnsureReady: EnsureReady?

    /// Opaque local JobServiceXPC object (JobServiceExportedObject) when running in derrickd.
    nonisolated(unsafe) public static var jobLocalProxy: AnyObject?
}
