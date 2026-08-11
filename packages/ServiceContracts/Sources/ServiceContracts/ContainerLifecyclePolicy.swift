import Foundation

/// Documented Docker container pool policy.
public struct ContainerLifecyclePolicy: Sendable, Hashable {
    /// Maximum networked containers alive at once (warm + in-flight).
    public let maxNetworkContainers: Int
    /// Maximum offline (`--network none`) containers alive at once.
    public let maxOfflineContainers: Int
    /// Count of pristine warm standbys kept ready when possible (network pool only).
    public let warmStandbyCount: Int
    /// Every exec container is destroyed after each run (success or failure).
    public let destroyAfterEveryRun: Bool
    /// Containers that executed user code are never returned without recreate.
    public let neverReusePostExecution: Bool

    /// Maximum seconds a single container lease may be held (queue wait excluded).
    public let containerRunMaxTTLSeconds: Int

    public init(
        maxNetworkContainers: Int,
        maxOfflineContainers: Int,
        warmStandbyCount: Int,
        containerRunMaxTTLSeconds: Int,
        destroyAfterEveryRun: Bool,
        neverReusePostExecution: Bool
    ) {
        self.maxNetworkContainers = maxNetworkContainers
        self.maxOfflineContainers = maxOfflineContainers
        self.warmStandbyCount = warmStandbyCount
        self.containerRunMaxTTLSeconds = containerRunMaxTTLSeconds
        self.destroyAfterEveryRun = destroyAfterEveryRun
        self.neverReusePostExecution = neverReusePostExecution
    }

    /// Locked product policy: network max 2 (1 warm), offline max 1 (queued, on-demand), 7m lease TTL.
    public static let derrickDefault = ContainerLifecyclePolicy(
        maxNetworkContainers: 2,
        maxOfflineContainers: 1,
        warmStandbyCount: 1,
        containerRunMaxTTLSeconds: 7 * 60,
        destroyAfterEveryRun: true,
        neverReusePostExecution: true
    )
}
