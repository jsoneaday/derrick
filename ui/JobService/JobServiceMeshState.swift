import Foundation

/// Tracks whether JobService has peer endpoints for MCP + Agent (required for execute/wake).
/// Scheduler refuses to claim jobs until both are installed (UI bootstrap).
final class JobServiceMeshState: @unchecked Sendable {
    static let shared = JobServiceMeshState()

    private let lock = NSLock()
    private var mcpPeerReady = false
    private var agentPeerReady = false

    private init() {}

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mcpPeerReady && agentPeerReady
    }

    func markMCPPeerReady() {
        lock.lock()
        mcpPeerReady = true
        let ready = mcpPeerReady && agentPeerReady
        lock.unlock()
        fputs("[JobService] mesh MCP peer ready (full=\(ready))\n", stderr)
    }

    func markAgentPeerReady() {
        lock.lock()
        agentPeerReady = true
        let ready = mcpPeerReady && agentPeerReady
        lock.unlock()
        fputs("[JobService] mesh Agent peer ready (full=\(ready))\n", stderr)
    }
}
