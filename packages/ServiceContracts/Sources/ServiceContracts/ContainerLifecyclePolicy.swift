import Foundation

/// Documented container pool policy for Phase 4 (Apple Container runtime).
/// Types only — no runtime implementation in this module.
public struct ContainerLifecyclePolicy: Sendable, Hashable {
    /// Maximum containers alive at once (warm standby + in-flight exec).
    public let maxAliveContainers: Int
    /// Count of pristine warm standbys kept ready (never ran user code).
    public let warmStandbyCount: Int
    /// Every exec container is destroyed after each run (success or failure).
    public let destroyAfterEveryRun: Bool
    /// Containers that executed user code are never returned to the warm pool.
    public let neverReusePostExecution: Bool

    public init(
        maxAliveContainers: Int,
        warmStandbyCount: Int,
        destroyAfterEveryRun: Bool,
        neverReusePostExecution: Bool
    ) {
        self.maxAliveContainers = maxAliveContainers
        self.warmStandbyCount = warmStandbyCount
        self.destroyAfterEveryRun = destroyAfterEveryRun
        self.neverReusePostExecution = neverReusePostExecution
    }

    /// Locked product policy: one pristine warm standby, max three alive, destroy-after-run.
    public static let derrickDefault = ContainerLifecyclePolicy(
        maxAliveContainers: 3,
        warmStandbyCount: 1,
        destroyAfterEveryRun: true,
        neverReusePostExecution: true
    )
}
