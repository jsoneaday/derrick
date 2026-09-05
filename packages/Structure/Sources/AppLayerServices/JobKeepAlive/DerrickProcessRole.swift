import Foundation

/// Process role flags shared across UI / daemon / legacy XPCs.
public enum DerrickProcessRole: Sendable {
    /// True inside `derrick.ui.Daemon` (JobKeepAlive LoginAgent).
    nonisolated(unsafe) public static var isDaemon = false
}
