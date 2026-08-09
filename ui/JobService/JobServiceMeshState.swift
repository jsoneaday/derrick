import Foundation

/// Tracks whether Job can reach Agent + MCP (peer mesh historically; in-process inside derrickd).
/// Scheduler refuses to claim jobs until ready.
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

    /// derrickd: Agent/MCP are in-process — no peer handoff required.
    func markInProcessReady() {
        lock.lock()
        mcpPeerReady = true
        agentPeerReady = true
        lock.unlock()
        fputs("[JobService] in-process Agent+MCP ready (daemon)\n", stderr)
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
