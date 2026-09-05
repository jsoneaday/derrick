import Foundation

public enum ServiceEnsureUpError: Error, LocalizedError, Sendable {
    case proxyUnavailable(String)
    case unavailable(String)
    case bootstrapFailed(String, String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .proxyUnavailable(let label):
            return "\(label) XPC proxy unavailable."
        case .unavailable(let label):
            return "\(label) is unavailable."
        case .bootstrapFailed(let label, let message):
            return "\(label) bootstrap failed: \(message)"
        case .timeout:
            return "Service ensure-up timed out."
        }
    }
}
