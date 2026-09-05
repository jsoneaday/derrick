import Foundation

/// Caps for hierarchical multi-agent orchestration (`agents_spawn`, mailboxes, concurrent turns).
public struct OrchestrationLimits: Hashable, Codable, Sendable, Equatable {
    /// Max hierarchy depth from the user-facing agent (depth 0). Default `2` → main → worker → sub-worker.
    public var maxDepth: Int
    /// Max direct children per parent (parallel workers in one spawn wave).
    public var maxChildrenPerAgent: Int
    /// Max concurrent LLM turns across all agents in a session.
    public var maxConcurrentTurns: Int
    /// Max registered agents in a session (includes the user-facing agent).
    public var maxAgentsPerSession: Int
    /// Max queued envelopes per agent mailbox.
    public var maxMailboxDepth: Int

    public init(
        maxDepth: Int = 2,
        maxChildrenPerAgent: Int = 4,
        maxConcurrentTurns: Int = 4,
        maxAgentsPerSession: Int = 8,
        maxMailboxDepth: Int = 64
    ) {
        self.maxDepth = maxDepth
        self.maxChildrenPerAgent = maxChildrenPerAgent
        self.maxConcurrentTurns = maxConcurrentTurns
        self.maxAgentsPerSession = maxAgentsPerSession
        self.maxMailboxDepth = maxMailboxDepth
    }

    /// Product defaults tuned for chat + modest parallel workers (see `docs/orchestration-limits.md`).
    public static let `default` = OrchestrationLimits(
        maxDepth: 2,
        maxChildrenPerAgent: 4,
        maxConcurrentTurns: 4,
        maxAgentsPerSession: 8,
        maxMailboxDepth: 64
    )

    /// Alias for AgentRuntime call sites.
    public static let recommended = `default`

    /// Hard ceilings for Settings and persisted config.
    public static let absoluteMax = OrchestrationLimits(
        maxDepth: 4,
        maxChildrenPerAgent: 8,
        maxConcurrentTurns: 8,
        maxAgentsPerSession: 16,
        maxMailboxDepth: 128
    )

    public func clamped() -> OrchestrationLimits {
        OrchestrationLimits(
            maxDepth: Self.clamp(maxDepth, min: 0, max: Self.absoluteMax.maxDepth),
            maxChildrenPerAgent: Self.clamp(
                maxChildrenPerAgent,
                min: 1,
                max: Self.absoluteMax.maxChildrenPerAgent
            ),
            maxConcurrentTurns: Self.clamp(
                maxConcurrentTurns,
                min: 1,
                max: Self.absoluteMax.maxConcurrentTurns
            ),
            maxAgentsPerSession: Self.clamp(
                maxAgentsPerSession,
                min: 2,
                max: Self.absoluteMax.maxAgentsPerSession
            ),
            maxMailboxDepth: Self.clamp(
                maxMailboxDepth,
                min: 8,
                max: Self.absoluteMax.maxMailboxDepth
            )
        )
    }

    private static func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.min(Swift.max(value, min), max)
    }
}

/// Process-wide orchestration limits (updated when Settings change; new sessions pick up latest).
public enum OrchestrationLimitsRuntime: Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var limits = OrchestrationLimits.`default`
    }

    private static let storage = Storage()

    public static var current: OrchestrationLimits {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.limits
    }

    public static func apply(_ limits: OrchestrationLimits) {
        storage.lock.lock()
        storage.limits = limits.clamped()
        storage.lock.unlock()
    }

    /// Test-only reset.
    public static func resetToDefaultForTesting() {
        apply(.default)
    }
}
