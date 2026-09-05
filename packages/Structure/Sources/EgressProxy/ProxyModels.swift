import Foundation

public enum ProxyDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

public struct ProxyDestination: Sendable, Equatable, Hashable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var displayName: String {
        "\(host):\(port)"
    }
}

public enum EgressProxyError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case policyDenied(String)
    case upstreamConnectFailed(String)
    case listenerFailed(String)
    case alreadyRunning
    case notRunning
}

extension EgressProxyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return "Invalid proxy request: \(message)"
        case .policyDenied(let reason):
            return "Proxy denied destination: \(reason)"
        case .upstreamConnectFailed(let message):
            return "Upstream connect failed: \(message)"
        case .listenerFailed(let message):
            return "Proxy listener failed: \(message)"
        case .alreadyRunning:
            return "Proxy is already running."
        case .notRunning:
            return "Proxy is not running."
        }
    }
}
