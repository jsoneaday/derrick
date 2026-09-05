import Foundation

/// Hard SSRF denials. Never user-overridable. Literals must stay lockstep with
/// `EgressProxyConfiguration` (see PluginTests + comment there). Plugin also
/// blocks IPv4-mapped IPv6 and NAT64.
public enum PluginSSRFPolicy: Sendable {
    /// Copied from `EgressProxyConfiguration.blockedHostnames`.
    public static let blockedHostnames: [String] = [
        "host.docker.internal",
        "gateway.docker.internal",
        "kubernetes.docker.internal",
        "metadata.google.internal",
        "metadata",
        "localhost",
    ]

    /// Copied from `EgressProxyConfiguration.blockedIPv4CIDRs`.
    public static let blockedIPv4CIDRs: [String] = [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "255.255.255.255/32",
    ]

    /// Copied from `EgressProxyConfiguration.blockedIPv6CIDRs` plus mapped/NAT64.
    public static let blockedIPv6CIDRs: [String] = [
        "::1/128",
        "fc00::/7",
        "fe80::/10",
        "ff00::/8",
        "::ffff:0:0/96",
        "64:ff9b::/96",
    ]

    public static let strippedRequestHeaders: Set<String> = [
        "authorization",
        "cookie",
        "proxy-authorization",
        "x-forwarded-for",
        "x-forwarded-host",
        "x-forwarded-proto",
    ]

    public static let strippedResponseHeaders: Set<String> = [
        "set-cookie",
        "authorization",
        "www-authenticate",
    ]

    public enum Denial: Equatable, Sendable {
        case emptyHost
        case blockedHostname(String)
        case literalIP(String)
        case blockedIPv4(String)
        case blockedIPv6(String)
        case disallowedScheme(String)
        case disallowedPort(Int)
        case localSuffix
    }

    public static func denyHostname(_ host: String) -> Denial? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return .emptyHost }
        if host.hasSuffix(".local") || host == "local" {
            return .localSuffix
        }
        if blockedHostnames.contains(host) {
            return .blockedHostname(host)
        }
        if IPv4Address(host) != nil {
            return .literalIP(host)
        }
        if host.contains(":"), IPv6Address.parse(host) != nil {
            return .literalIP(host)
        }
        return nil
    }

    public static func denyResolvedAddress(_ address: String) -> Denial? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ipv4 = IPv4Address(address) {
            if blockedIPv4.contains(where: { $0.contains(ipv4) }) {
                return .blockedIPv4(address)
            }
            return nil
        }
        if let ipv6 = IPv6Address.parse(address) {
            if blockedIPv6.contains(where: { $0.contains(ipv6) }) {
                return .blockedIPv6(address)
            }
            if let mapped = ipv6.mappedIPv4, blockedIPv4.contains(where: { $0.contains(mapped) }) {
                return .blockedIPv6(address)
            }
            return nil
        }
        return nil
    }

    public static func denyURL(_ url: URL) -> Denial? {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme != "https" && scheme != "http" {
            return .disallowedScheme(scheme.isEmpty ? "(none)" : scheme)
        }
        if let port = url.port, port != 80, port != 443 {
            return .disallowedPort(port)
        }
        return denyHostname(url.host ?? "")
    }

    public static func stripRequestHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { !strippedRequestHeaders.contains($0.key.lowercased()) }
    }

    public static func stripResponseHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { !strippedResponseHeaders.contains($0.key.lowercased()) }
    }

    private static let blockedIPv4: [IPv4CIDR] = blockedIPv4CIDRs.compactMap(IPv4CIDR.init)
    private static let blockedIPv6: [IPv6Prefix] = blockedIPv6CIDRs.compactMap(IPv6Prefix.init)
}

// MARK: - IP helpers (local copies; do not import EgressProxy)

struct IPv4Address: Equatable {
    let value: UInt32

    init?(_ string: String) {
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        value = UInt32(bigEndian: addr.s_addr)
    }
}

struct IPv4CIDR {
    let network: UInt32
    let prefix: UInt8

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let ip = IPv4Address(String(parts[0])),
              let prefix = UInt8(parts[1]),
              prefix <= 32 else { return nil }
        self.prefix = prefix
        if prefix == 0 {
            network = 0
        } else {
            let mask = prefix == 32 ? UInt32.max : UInt32.max << (32 - Int(prefix))
            network = ip.value & mask
        }
    }

    func contains(_ ip: IPv4Address) -> Bool {
        if prefix == 0 { return true }
        let mask = prefix == 32 ? UInt32.max : UInt32.max << (32 - Int(prefix))
        return (ip.value & mask) == network
    }
}

struct IPv6Address: Equatable {
    let bytes: [UInt8]

    static func parse(_ string: String) -> IPv6Address? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, string, &addr) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        return IPv6Address(bytes: bytes)
    }

    var mappedIPv4: IPv4Address? {
        guard bytes.count == 16 else { return nil }
        let prefix = bytes.prefix(10).allSatisfy { $0 == 0 }
        let next = bytes[10] == 0xff && bytes[11] == 0xff
        guard prefix && next else { return nil }
        let v = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
        return IPv4Address(value: v)
    }
}

private extension IPv4Address {
    init(value: UInt32) {
        self.value = value
    }
}

struct IPv6Prefix {
    let bytes: [UInt8]
    let prefix: Int

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let addr = IPv6Address.parse(String(parts[0])),
              let prefix = Int(parts[1]),
              prefix >= 0, prefix <= 128 else { return nil }
        self.bytes = addr.bytes
        self.prefix = prefix
    }

    func contains(_ ip: IPv6Address) -> Bool {
        guard ip.bytes.count == 16, bytes.count == 16 else { return false }
        if prefix == 0 { return true }
        let fullBytes = prefix / 8
        let rem = prefix % 8
        if fullBytes > 0, Array(ip.bytes.prefix(fullBytes)) != Array(bytes.prefix(fullBytes)) {
            return false
        }
        if rem == 0 { return true }
        let mask = UInt8(truncatingIfNeeded: 0xff << (8 - rem))
        return (ip.bytes[fullBytes] & mask) == (bytes[fullBytes] & mask)
    }
}
