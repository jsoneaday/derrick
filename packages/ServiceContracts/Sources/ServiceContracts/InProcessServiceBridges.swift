import Foundation

/// Optional in-process implementations installed by derrickd so SharedAgentRuntime
/// clients can skip XPC when Agent/Job/MCP share the daemon process.
public enum InProcessServiceBridges: Sendable {
    public typealias CallTool = @Sendable (MCPToolCallRequest) async throws -> MCPToolCallResultDTO
    public typealias SearchTools = @Sendable (ServicePrincipal, String) async throws -> MCPToolSearchResultDTO
    public typealias EnsureReady = @Sendable () async throws -> Void
    /// Job script network banner preflight (toolName, argumentsJSON, jobID).
    public typealias JobNetworkPreflight =
        @Sendable (_ toolName: String, _ argumentsJSON: String, _ jobID: String) async throws -> Void

    nonisolated(unsafe) public static var mcpCallTool: CallTool?
    nonisolated(unsafe) public static var mcpSearchTools: SearchTools?
    nonisolated(unsafe) public static var mcpEnsureReady: EnsureReady?

    /// Opaque local JobServiceXPC object (JobServiceExportedObject) when running in derrickd.
    nonisolated(unsafe) public static var jobLocalProxy: AnyObject?

    /// Installed by derrickd: banner-based network approval before scheduled script jobs.
    nonisolated(unsafe) public static var jobNetworkPreflight: JobNetworkPreflight?

    public typealias StartWorkflow = @Sendable (WorkflowStartRequest) async throws -> WorkflowHandleDTO
    public typealias PollWorkflow = @Sendable (WorkflowPollRequest) async throws -> WorkflowPollResultDTO
    public typealias CancelWorkflow = @Sendable (WorkflowCancelRequest) async throws -> ServiceAckDTO

    nonisolated(unsafe) public static var workflowStart: StartWorkflow?
    nonisolated(unsafe) public static var workflowPoll: PollWorkflow?
    nonisolated(unsafe) public static var workflowCancel: CancelWorkflow?

    public typealias SubmitConnectorOperation =
        @Sendable (ConnectorOperationRequest) async throws -> ConnectorOperationAckDTO
    public typealias PollConnectorOperation =
        @Sendable (ConnectorOperationPollRequest) async throws -> ConnectorOperationPollResult

    nonisolated(unsafe) public static var connectorSubmit: SubmitConnectorOperation?
    nonisolated(unsafe) public static var connectorPoll: PollConnectorOperation?
}
