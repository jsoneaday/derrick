import Foundation

public enum ConnectorMessagingClientError: Error, LocalizedError, Sendable {
    case unavailable
    case decodeFailed
    case notAccepted(String)
    case operationFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Connector messaging commands are not available."
        case .decodeFailed:
            return "Connector messaging returned an invalid response."
        case .notAccepted(let message):
            return message
        case .operationFailed(let detail):
            return detail
        case .timedOut:
            return "Connector messaging timed out."
        }
    }

    public static func isTimeout(_ error: Error) -> Bool {
        if case .timedOut = error as? ConnectorMessagingClientError {
            return true
        }
        let text = error.localizedDescription
        return text.localizedCaseInsensitiveContains("Connector messaging timed out")
    }
}
