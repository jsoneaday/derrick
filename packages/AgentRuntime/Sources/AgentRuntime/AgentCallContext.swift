import Foundation

/// Task-local caller identity for nested / concurrent agent turns (MA-3).
///
/// Prefer this over a shared mutable "current caller" so parallel workers do not clobber each other.
public enum AgentCallContext: Sendable {
    @TaskLocal public static var caller: AgentRef?
}
