import Foundation

/// Compile-time egress policy and listen settings.
/// Edit this file to change allow/deny defaults — not runtime tool args.
public enum EgressProxyConfiguration: Sendable {
    /// Interface the proxy binds to on the host (helper process).
    /// Must stay loopback unless you intentionally expose the proxy (not recommended).
    /// `EgressProxyServer` sets `requiredLocalEndpoint` to this host so it does not bind all interfaces.
    public static let listenHost: String = "127.0.0.1"

    /// Fixed loopback port reserved for the standalone proxy service.
    public static let listenPort: UInt16 = 18_080

    /// Max concurrent client connections.
    public static let maxConcurrentConnections: Int = 32

    /// Idle timeout for a single proxied stream (seconds).
    public static let streamIdleTimeoutSeconds: TimeInterval = 60

    /// Connect timeout to upstream (seconds).
    public static let upstreamConnectTimeoutSeconds: TimeInterval = 15

    /// Default suffixes seeded into the app DB on first launch.
    /// Live allow decisions use the DB-backed list pushed into the helper — not this array at request time.
    public static let defaultSeedDomainSuffixes: [String] = [
        "github.com",
        "githubusercontent.com"
    ]

    /// Hostnames that are always rejected (host/metadata SSRF).
    public static let blockedHostnames: [String] = [
        "host.docker.internal",
        "gateway.docker.internal",
        "kubernetes.docker.internal",
        "metadata.google.internal",
        "metadata",
        "localhost"
    ]

    /// IPv4 CIDR blocks that are always rejected after DNS resolution.
    public static let blockedIPv4CIDRs: [String] = [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "255.255.255.255/32"
    ]

    /// IPv6 prefixes that are always rejected after DNS resolution.
    public static let blockedIPv6CIDRs: [String] = [
        "::1/128",
        "fc00::/7",
        "fe80::/10",
        "ff00::/8"
    ]

}
