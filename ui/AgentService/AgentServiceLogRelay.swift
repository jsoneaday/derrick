import Foundation
import ServiceContracts

/// Process-wide reverse-XPC log fan-out: AgentService → UI debug panel.
///
/// The UI exports `AgentServiceClientSinkXPC` on the live connection. We resolve a
/// fresh proxy per line so we do not hold a stale remote object across interruptions.
final class AgentServiceLogRelay: @unchecked Sendable {
    static let shared = AgentServiceLogRelay()

    private let lock = NSLock()
    private weak var connection: NSXPCConnection?

    private init() {}

    func attach(connection: NSXPCConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    func detach(connection: NSXPCConnection) {
        lock.lock()
        if self.connection === connection {
            self.connection = nil
        }
        lock.unlock()
    }

    /// Push a line to the UI sink when connected; no-op if UI is not attached yet.
    func publish(_ message: String) {
        guard Self.shouldRelayToUI(message) else { return }

        lock.lock()
        let conn = connection
        lock.unlock()
        guard let conn else { return }

        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            fputs(
                "[AgentService] log sink error: \(error.localizedDescription)\n",
                stderr
            )
        }
        guard let sink = proxy as? AgentServiceClientSinkXPC else { return }
        sink.appendServiceLogLine(message)
    }

    /// Drop seed noise and huge LLM dump lines so tool/runtime path stays visible in the UI (capped store).
    static func shouldRelayToUI(_ message: String) -> Bool {
        if message.contains("Memory DB migrations")
            || message.contains("Policy seed skipped")
            || message.contains("Egress allowlist seed skipped") {
            return false
        }
        // Full prompt dumps fill DebugLogStore; keep short status lines only.
        if message.hasPrefix("LLM request (") || message.hasPrefix("LLM response (") {
            return false
        }
        if message.contains("LLM request (round") || message.contains("LLM response (round") {
            return false
        }
        return true
    }
}
