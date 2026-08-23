import Foundation
import ServiceContracts

/// Single entry for UI-hosted daemon hygiene: evict stale copies, refresh registration, kickstart.
enum DaemonBootstrapCoordinator {
    nonisolated(unsafe) private static var lastPrepareAt = Date.distantPast
    private static let debounceInterval: TimeInterval = 1_800

    /// Evict orphan/stale `JobKeepAlive` and ensure launchd targets this host app bundle.
    @discardableResult
    static func prepareForHostApp(force: Bool = false) async -> Bool {
        guard !JobResultPanelSession.isPanelOnlyLaunch,
              !DerrickNotificationLaunch.hasJobResultPresentationIntent(),
              !DerrickNotificationLaunch.hasHITLApprovalPresentationIntent()
        else {
            return true
        }
        if !force {
            let elapsed = Date().timeIntervalSince(lastPrepareAt)
            guard elapsed >= debounceInterval else {
                fputs("[DaemonHygiene] prepare skipped (debounce \(Int(elapsed))s)\n", stderr)
                return true
            }
        }
        let result = await DaemonProcessHygiene.reconcile()
        lastPrepareAt = Date()
        return result
    }
}
