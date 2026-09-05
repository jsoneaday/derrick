import AppKit
import AppKit
import Foundation
import Structure

/// Process-wide reverse channel to the UI app.
/// Job-sourced `startTurn` connections export a silent sink; we still stream those turns
/// into the UI so scheduled job wakes appear in chat.
final class AgentServicePrimaryUISink: @unchecked Sendable {
    static let shared = AgentServicePrimaryUISink()

    private let lock = NSLock()
    private weak var connection: NSXPCConnection?

    private init() {}

    /// Adopt `connection` only when it exports `AgentServiceClientSinkXPC` (AgentServiceClient).
    /// Job/MCP host clients open additional daemon Mach connections from the same UI process;
    /// they must not replace the reverse sink used for HITL and turn streaming.
    func attach(connection: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        if let current = self.connection, current === connection { return }
        if let current = self.connection, current !== connection, peerIsAlive(current) {
            fputs(
                "[AgentService] primary UI sink attach skipped pid=\(connection.processIdentifier) (keeping pid=\(current.processIdentifier))\n",
                stderr
            )
            return
        }
        self.connection = connection
        fputs("[AgentService] primary UI sink attached pid=\(connection.processIdentifier)\n", stderr)
    }

    func detach(connection: NSXPCConnection) {
        lock.lock()
        if self.connection === connection {
            self.connection = nil
            fputs("[AgentService] primary UI sink detached pid=\(connection.processIdentifier)\n", stderr)
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

    private func peerIsAlive(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard pid > 0 else { return false }
        return NSRunningApplication(processIdentifier: pid) != nil
    }
}
