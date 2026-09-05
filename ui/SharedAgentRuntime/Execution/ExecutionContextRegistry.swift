import AgentRuntime
import Foundation
import Structure

/// Registry of per-session/agent execution contexts (replaces process-wide turn slots).
public final class ExecutionContextRegistry: @unchecked Sendable {
    public static let shared = ExecutionContextRegistry()

    private let lock = NSLock()
    private var slotsByID: [ExecutionContextID: ExecutionContextSlots] = [:]
    /// Active turn per session (serial turn queue guarantees one in-flight turn per session).
    private var activeBySession: [String: ExecutionContextID] = [:]

    private init() {}

    public func install(_ id: ExecutionContextID, slots: ExecutionContextSlots) {
        lock.lock()
        slotsByID[id] = slots
        activeBySession[id.sessionID] = id
        lock.unlock()
    }

    public func remove(_ id: ExecutionContextID) {
        lock.lock()
        slotsByID.removeValue(forKey: id)
        if activeBySession[id.sessionID] == id {
            activeBySession.removeValue(forKey: id.sessionID)
        }
        lock.unlock()
    }

    /// Forks parent turn slots for a worker agent without replacing the session's active user-facing context.
    public func installDerived(_ child: ExecutionContextID, from parent: ExecutionContextID) {
        lock.lock()
        if let parentSlots = slotsByID[parent] {
            slotsByID[child] = parentSlots
        }
        lock.unlock()
    }

    /// Removes a derived worker context only (does not clear session active context).
    public func removeDerived(_ child: ExecutionContextID) {
        lock.lock()
        slotsByID.removeValue(forKey: child)
        lock.unlock()
    }

    public func slots(for id: ExecutionContextID) -> ExecutionContextSlots? {
        lock.lock()
        defer { lock.unlock() }
        return slotsByID[id]
    }

    public func slots(forSession sessionID: String) -> ExecutionContextSlots? {
        lock.lock()
        defer { lock.unlock() }
        guard let active = activeBySession[sessionID] else { return nil }
        return slotsByID[active]
    }

    public func setPluginFactoryCreationActive(forSession sessionID: String, active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let contextID = activeBySession[sessionID],
              var slots = slotsByID[contextID] else {
            return
        }
        slots.pluginFactoryCreationActive = active
        slotsByID[contextID] = slots
    }

    public func resolve(
        contextID: ExecutionContextID?,
        caller: AgentRef? = nil
    ) -> ExecutionContextSlots? {
        lock.lock()
        defer { lock.unlock() }
        if let contextID, let slots = slotsByID[contextID] {
            return slots
        }
        if let caller {
            let id = ExecutionContextID(agentRef: caller)
            if let slots = slotsByID[id] {
                return slots
            }
        }
        return nil
    }

    /// Fallback when MCP tool tasks lack TaskLocal/caller but only one session has an active turn.
    public func slotsWhenUnambiguous() -> ExecutionContextSlots? {
        lock.lock()
        defer { lock.unlock() }
        guard activeBySession.count == 1,
              let id = activeBySession.values.first,
              let slots = slotsByID[id]
        else {
            return nil
        }
        return slots
    }

    #if DEBUG
    /// Test-only reset.
    func resetForTesting() {
        lock.lock()
        slotsByID.removeAll()
        activeBySession.removeAll()
        lock.unlock()
    }
    #endif
}

public extension ExecutionContextID {
    init(agentRef: AgentRef) {
        self.init(sessionID: agentRef.sessionID, agentID: agentRef.agentID)
    }
}
