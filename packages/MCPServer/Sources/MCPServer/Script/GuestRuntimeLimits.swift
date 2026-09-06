import Foundation
import Structure

/// Shared offline-guest timeout and container lease limits.
public enum GuestRuntimeLimits: Sendable {
    public static let defaultTimeoutSeconds = 60
    public static let maxTimeoutSeconds = 300

    public static var containerRunMaxTTLSeconds: Int {
        ContainerLifecycleRuntime.containerRunMaxTTLSeconds
    }

    public static func effectiveScriptTimeoutSeconds(requested: Int) -> Int {
        min(max(requested, 1), containerRunMaxTTLSeconds)
    }

    public static func containerLeaseExceededExplanation(
        maxSeconds: Int = containerRunMaxTTLSeconds
    ) -> String {
        let minutes = maxSeconds / 60
        return """
        Guest container lease expired after \(maxSeconds)s (\(minutes) minutes). Each script_exec run may hold a container for at most \(maxSeconds)s so other agents are not blocked. Shorten the script, lower timeout_seconds, or split the work into smaller runs.
        """
    }
}
