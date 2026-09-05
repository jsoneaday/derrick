import Foundation

public enum MCPServiceClientError: Error, LocalizedError, Sendable {
    case unavailable
    case bootstrapFailed(String)
    case peerEndpointMissing
    case meshUnverified(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "MCPService is unavailable."
        case .bootstrapFailed(let message):
            return "MCPService bootstrap failed: \(message)"
        case .peerEndpointMissing:
            return "MCPService peer endpoint not installed."
        case .meshUnverified(let message):
            return "Agent→MCPService mesh failed verification: \(message)"
        case .timeout:
            return "MCPService XPC call timed out."
        }
    }
}

public enum WorkflowRuntimeClientError: Error, LocalizedError, Sendable {
    case unavailable
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Workflow runtime is not available."
        case .decodeFailed:
            return "Workflow runtime returned an invalid response."
        }
    }
}

public enum MCPClientError: Error, Sendable {
    case toolExecutionDenied(toolName: String, reason: String)
}

extension MCPClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .toolExecutionDenied(let toolName, let reason):
            return "\(toolName) \(reason)"
        }
    }
}
