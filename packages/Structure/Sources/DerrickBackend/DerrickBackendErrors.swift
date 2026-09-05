import Foundation

public enum DaemonModuleID: String, Sendable, CaseIterable {
    case events
    case notifications
    case ingress
    case jobs
    case agent
    case mcp
}

public enum DaemonRuntimeError: Error, LocalizedError, Sendable {
    case databaseUnavailable

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "Daemon database unavailable"
        }
    }
}

public enum DaemonClientError: Error, LocalizedError, Sendable {
    case unavailable
    case timeout
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Derrick daemon unavailable"
        case .timeout: return "Derrick daemon call timed out"
        case .rejected(let m): return m
        }
    }
}

public enum WorkflowRuntimeError: Error, LocalizedError, Sendable {
    case mcpUnavailable
    case workflowNotFound
    case unsupportedKind(WorkflowKind)

    public var errorDescription: String? {
        switch self {
        case .mcpUnavailable:
            return "MCP tool host is not available in-process."
        case .workflowNotFound:
            return "Workflow was not found."
        case .unsupportedKind(let kind):
            return "Unsupported workflow kind \(kind.rawValue)."
        }
    }
}

public enum ConnectorMessagingCommandError: Error, LocalizedError, Equatable, Sendable {
    case duplicateOperationID
    case operationNotFound
    case invalidRequest(String)
    case connectorUnavailable(String)
    case credentialsMissing

    public var errorDescription: String? {
        switch self {
        case .duplicateOperationID:
            return "A connector operation with this id is already running."
        case .operationNotFound:
            return "Connector operation was not found."
        case .invalidRequest(let detail):
            return detail
        case .connectorUnavailable(let pluginID):
            return "Messaging connector '\(pluginID)' is not available."
        case .credentialsMissing:
            return "Connector credentials are missing."
        }
    }
}

public enum NotificationPostingError: Error, LocalizedError, Sendable {
    case denied
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .denied: return "Notification permission denied for derrick.ui.Daemon — enable in System Settings → Notifications → DerrickDaemon"
        case .notAuthorized: return "Notification permission not granted for derrick.ui.Daemon"
        }
    }
}
