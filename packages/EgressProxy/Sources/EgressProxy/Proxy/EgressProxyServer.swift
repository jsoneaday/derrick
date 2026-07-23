import Foundation
import Network

/// Lifecycle for an egress proxy process.
public protocol EgressProxyServing: Sendable {
    var isRunning: Bool { get async }
    var listenPort: UInt16 { get async }
    func start() async throws
    func stop() async
}

/// HTTP CONNECT (and absolute-form HTTP) forward proxy with destination policy.
public actor EgressProxyServer: EgressProxyServing {
    private let policy: any DestinationPolicy
    private let logger: any EgressProxyLogging
    private let configuredPort: UInt16
    private let listenHost: String
    private let maxConcurrentConnections: Int

    private var listener: NWListener?
    private var activeConnections = 0
    private var running = false
    private var boundPort: UInt16

    public init(
        policy: any DestinationPolicy = DefaultDestinationPolicy(),
        logger: any EgressProxyLogging = OSLogEgressProxyLogger(),
        listenHost: String = EgressProxyConfiguration.listenHost,
        listenPort: UInt16 = EgressProxyConfiguration.listenPort,
        maxConcurrentConnections: Int = EgressProxyConfiguration.maxConcurrentConnections
    ) {
        self.policy = policy
        self.logger = logger
        self.listenHost = listenHost
        self.configuredPort = listenPort
        self.boundPort = listenPort
        self.maxConcurrentConnections = maxConcurrentConnections
    }

    public var isRunning: Bool { running }

    public var listenPort: UInt16 { boundPort }

    public func start() async throws {
        guard !running else { throw EgressProxyError.alreadyRunning }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let port = NWEndpoint.Port(rawValue: configuredPort)
            ?? NWEndpoint.Port(rawValue: 18_080)!

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw EgressProxyError.listenerFailed(error.localizedDescription)
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }

        let started: Bool = try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resumeOnce {
                        continuation.resume(returning: true)
                    }
                case .failed(let error):
                    gate.resumeOnce {
                        continuation.resume(throwing: EgressProxyError.listenerFailed(error.localizedDescription))
                    }
                case .cancelled:
                    gate.resumeOnce {
                        continuation.resume(throwing: EgressProxyError.listenerFailed("listener cancelled"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        guard started else {
            throw EgressProxyError.listenerFailed("listener did not become ready")
        }

        if let nwPort = listener.port {
            boundPort = nwPort.rawValue
        }
        self.listener = listener
        running = true
        logger.logInfo("listening on \(listenHost):\(boundPort)")
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        running = false
        logger.logInfo("stopped")
    }

    private func accept(_ connection: NWConnection) async {
        if activeConnections >= maxConcurrentConnections {
            logger.logError("rejecting connection: max concurrent connections reached")
            connection.cancel()
            return
        }
        activeConnections += 1
        defer { activeConnections -= 1 }

        connection.start(queue: .global(qos: .userInitiated))
        let handler = ProxyConnectionHandler(
            connection: connection,
            policy: policy,
            logger: logger
        )
        await handler.run()
    }
}
