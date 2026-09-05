import Foundation
import Structure

/// Optional hooks for host apps (UI) to run before connecting to the headless daemon.
public enum ServiceEnsureUpHooks: Sendable {
    nonisolated(unsafe) public static var beforeEnsureDaemon: (@Sendable () async -> Void)?
}
