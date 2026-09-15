import Foundation

/// Locked Docker container lifecycle.
///
/// Recreate on every handoff: `docker create` from a cached image, run, `docker rm`.
/// Never reuse a container that already executed guest or product code.
/// Skip image pull/build when `docker image inspect` succeeds.
/// Each kind of work has its own queue and cap.
public struct ContainerLifecyclePolicy: Sendable, Hashable {
    /// Maximum crawler containers at once (oneshot; own queue).
    public let maxNetworkContainers: Int
    /// Maximum offline Go guest containers at once (`script_exec` / `plugin.invoke`).
    public let maxOfflineContainers: Int
    /// Maximum file-extractor containers at once (oneshot; own queue).
    public let maxFileExtractContainers: Int
    /// Warm idle standbys. Always 0: we recreate on handoff instead of keeping a live box.
    public let warmStandbyCount: Int
    /// Every exec container is destroyed after each run (success or failure).
    public let destroyAfterEveryRun: Bool
    /// Containers that executed user code are never handed to the next job.
    public let neverReusePostExecution: Bool

    /// Maximum seconds a single in-use container lease may be held (queue wait excluded).
    public let containerRunMaxTTLSeconds: Int

    public init(
        maxNetworkContainers: Int,
        maxOfflineContainers: Int,
        maxFileExtractContainers: Int,
        warmStandbyCount: Int,
        containerRunMaxTTLSeconds: Int,
        destroyAfterEveryRun: Bool,
        neverReusePostExecution: Bool
    ) {
        self.maxNetworkContainers = maxNetworkContainers
        self.maxOfflineContainers = maxOfflineContainers
        self.maxFileExtractContainers = maxFileExtractContainers
        self.warmStandbyCount = warmStandbyCount
        self.containerRunMaxTTLSeconds = containerRunMaxTTLSeconds
        self.destroyAfterEveryRun = destroyAfterEveryRun
        self.neverReusePostExecution = neverReusePostExecution
    }

    /// Recreate-on-handoff. Images stay cached. Separate queues: crawl 2, script 1, extract 1.
    public static let derrickDefault = ContainerLifecyclePolicy(
        maxNetworkContainers: 2,
        maxOfflineContainers: 1,
        maxFileExtractContainers: 1,
        warmStandbyCount: 0,
        containerRunMaxTTLSeconds: 7 * 60,
        destroyAfterEveryRun: true,
        neverReusePostExecution: true
    )
}
