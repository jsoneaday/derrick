import Foundation

/// Lifecycle for an egress proxy process.
public protocol EgressProxyServing: Sendable {
    var isRunning: Bool { get async }
    var listenPort: UInt16 { get async }
    func start() async throws
    func stop() async
}

/// Observability for proxy decisions. Unauthorized attempts must be logged.
public protocol EgressProxyLogging: Sendable {
    func logInfo(_ message: String)
    func logUnauthorizedAccess(destination: ProxyDestination, reason: String, clientDescription: String?)
    func logAllowedAccess(destination: ProxyDestination, clientDescription: String?)
    func logError(_ message: String)
}
