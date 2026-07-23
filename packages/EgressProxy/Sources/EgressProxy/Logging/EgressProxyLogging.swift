import Foundation
import os.log

/// Observability for proxy decisions. Unauthorized attempts must be logged.
public protocol EgressProxyLogging: Sendable {
    func logInfo(_ message: String)
    func logUnauthorizedAccess(destination: ProxyDestination, reason: String, clientDescription: String?)
    func logAllowedAccess(destination: ProxyDestination, clientDescription: String?)
    func logError(_ message: String)
}

public struct OSLogEgressProxyLogger: EgressProxyLogging {
    private let logger: Logger

    public init(subsystem: String = "EgressProxy", category: String = "proxy") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func logUnauthorizedAccess(destination: ProxyDestination, reason: String, clientDescription: String?) {
        let client = clientDescription ?? "unknown"
        logger.error(
            "UNAUTHORIZED_EGRESS attempt destination=\(destination.displayName, privacy: .public) reason=\(reason, privacy: .public) client=\(client, privacy: .public)"
        )
    }

    public func logAllowedAccess(destination: ProxyDestination, clientDescription: String?) {
        let client = clientDescription ?? "unknown"
        logger.info(
            "egress allow destination=\(destination.displayName, privacy: .public) client=\(client, privacy: .public)"
        )
    }

    public func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

/// Multiplexes to multiple log sinks (e.g. os_log + app debug relay).
public struct MultiplexEgressProxyLogger: EgressProxyLogging {
    private let sinks: [any EgressProxyLogging]

    public init(sinks: [any EgressProxyLogging]) {
        self.sinks = sinks
    }

    public func logInfo(_ message: String) {
        for sink in sinks { sink.logInfo(message) }
    }

    public func logUnauthorizedAccess(destination: ProxyDestination, reason: String, clientDescription: String?) {
        for sink in sinks {
            sink.logUnauthorizedAccess(destination: destination, reason: reason, clientDescription: clientDescription)
        }
    }

    public func logAllowedAccess(destination: ProxyDestination, clientDescription: String?) {
        for sink in sinks {
            sink.logAllowedAccess(destination: destination, clientDescription: clientDescription)
        }
    }

    public func logError(_ message: String) {
        for sink in sinks { sink.logError(message) }
    }
}

/// Closure-based sink for wiring into existing app log relays.
public struct CallbackEgressProxyLogger: EgressProxyLogging, @unchecked Sendable {
    private let handler: @Sendable (String) -> Void

    public init(handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    public func logInfo(_ message: String) {
        handler("[EgressProxy] \(message)")
    }

    public func logUnauthorizedAccess(destination: ProxyDestination, reason: String, clientDescription: String?) {
        let client = clientDescription ?? "unknown"
        handler(
            "[EgressProxy] UNAUTHORIZED_EGRESS destination=\(destination.displayName) reason=\(reason) client=\(client)"
        )
    }

    public func logAllowedAccess(destination: ProxyDestination, clientDescription: String?) {
        let client = clientDescription ?? "unknown"
        handler("[EgressProxy] allow destination=\(destination.displayName) client=\(client)")
    }

    public func logError(_ message: String) {
        handler("[EgressProxy] ERROR \(message)")
    }
}
