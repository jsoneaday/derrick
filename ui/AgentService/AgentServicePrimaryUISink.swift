import Foundation
import ServiceContracts

/// Process-wide reverse channel to the UI app.
/// Job-sourced `startTurn` connections export a silent sink; we still stream those turns
/// into the UI so scheduled job wakes appear in chat.
final class AgentServicePrimaryUISink: @unchecked Sendable {
    static let shared = AgentServicePrimaryUISink()

    private let lock = NSLock()
    private weak var connection: NSXPCConnection?

    private init() {}

    func attach(connection: NSXPCConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
        fputs("[AgentService] primary UI sink attached pid=\(connection.processIdentifier)\n", stderr)
    }

    func detach(connection: NSXPCConnection) {
        lock.lock()
        if self.connection === connection {
            self.connection = nil
        }
        lock.unlock()
    }

    /// True when `connection` is the UI reverse channel we already stream to.
    func isPrimaryConnection(_ connection: NSXPCConnection?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let connection, let primary = self.connection else { return false }
        return connection === primary
    }

    func clientSink(logLabel: String) -> AgentServiceClientSinkXPC? {
        lock.lock()
        let conn = connection
        lock.unlock()
        guard let conn else {
            // Quiet: job-only / pre-UI boots have no primary yet.
            return nil
        }
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            fputs(
                "[AgentService] \(logLabel): UI sink proxy error: \(error.localizedDescription)\n",
                stderr
            )
        }
        guard let sink = proxy as? AgentServiceClientSinkXPC else {
            fputs("[AgentService] \(logLabel): primary reverse proxy not AgentServiceClientSinkXPC\n", stderr)
            return nil
        }
        return sink
    }
}
