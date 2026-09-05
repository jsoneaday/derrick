import Foundation

/// Evaluates whether a destination may be reached through the proxy.
public protocol DestinationPolicy: Sendable {
    func evaluate(destination: ProxyDestination) async -> ProxyDecision
}

/// Resolves hostnames for post-resolve IP policy checks.
public protocol DNSResolving: Sendable {
    func resolveAddresses(for host: String) async throws -> [String]
}

/// User decision for a host that is not yet on the permanent/session allowlist.
public enum HostAccessUserDecision: Sendable, Equatable {
    case allowOnce
    case allowAlways
    case deny
}

/// Asks the controlling app (via reverse XPC) whether an unknown host may be reached.
/// Used mid-flight when CONNECT targets a host preflight did not cover.
public protocol HostAccessPrompter: Sendable {
    func requestAccess(host: String) async -> HostAccessUserDecision
}
