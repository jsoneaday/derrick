import Foundation
import ServiceContracts

/// System overlays for hierarchical roles (MA-2).
public enum WorkerOverlays: Sendable {
    /// Workers do not chat with the end user; they complete assigned tasks.
    public static var workerDefault: String {
        DerrickBundledText.mustLoad("worker_overlay.md")
    }

    public static var userFacingWithSpawn: String {
        DerrickBundledText.mustLoad("user_facing_spawn_overlay.md")
    }
}
