import Foundation

public enum AgentServiceClientError: Error, LocalizedError, Sendable {
    case unavailable
    case bootstrapFailed(String)
    case turnFailed(String)
    case rejected(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "AgentService is unavailable. Check service_logs and that AgentService.xpc is embedded."
        case .bootstrapFailed(let message):
            return "AgentService bootstrap failed: \(message)"
        case .turnFailed(let message):
            return "AgentService turn failed: \(message)"
        case .rejected(let message):
            return message
        case .timeout:
            return "AgentService XPC call timed out."
        }
    }
}
