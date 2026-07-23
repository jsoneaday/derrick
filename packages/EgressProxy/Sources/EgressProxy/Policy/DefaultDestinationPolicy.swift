import Foundation

/// Hardcoded allow/deny policy driven by `EgressProxyConfiguration`.
public struct DefaultDestinationPolicy: DestinationPolicy {
    private let allowedDomainSuffixes: [String]
    private let blockedHostnames: [String]
    private let blockedIPv4: [IPv4CIDR]
    private let blockedIPv6: [IPv6Prefix]
    private let resolver: any DNSResolving

    public init(
        allowedDomainSuffixes: [String] = EgressProxyConfiguration.allowedDomainSuffixes,
        blockedHostnames: [String] = EgressProxyConfiguration.blockedHostnames,
        blockedIPv4CIDRs: [String] = EgressProxyConfiguration.blockedIPv4CIDRs,
        blockedIPv6CIDRs: [String] = EgressProxyConfiguration.blockedIPv6CIDRs,
        resolver: any DNSResolving = SystemDNSResolver()
    ) {
        self.allowedDomainSuffixes = allowedDomainSuffixes.map { $0.lowercased() }
        self.blockedHostnames = blockedHostnames.map { $0.lowercased() }
        self.blockedIPv4 = blockedIPv4CIDRs.compactMap(IPv4CIDR.init)
        self.blockedIPv6 = blockedIPv6CIDRs.compactMap(IPv6Prefix.init)
        self.resolver = resolver
    }

    public func evaluate(destination: ProxyDestination) async -> ProxyDecision {
        let host = destination.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else {
            return .deny(reason: "empty host")
        }

        if blockedHostnames.contains(host) {
            return .deny(reason: "hostname is blocked: \(host)")
        }

        if let ipv4 = IPv4Address(host) {
            if isBlocked(ipv4: ipv4) {
                return .deny(reason: "IPv4 address is in a blocked range: \(host)")
            }
            return .deny(reason: "raw IPv4 destinations are not allowlisted: \(host)")
        }

        if host.contains(":"), let ipv6 = IPv6Address.parse(host) {
            if isBlocked(ipv6: ipv6) {
                return .deny(reason: "IPv6 address is in a blocked range: \(host)")
            }
            return .deny(reason: "raw IPv6 destinations are not allowlisted: \(host)")
        }

        guard isAllowedDomain(host) else {
            return .deny(reason: "hostname not in allowlist: \(host)")
        }

        do {
            let addresses = try await resolver.resolveAddresses(for: host)
            if addresses.isEmpty {
                return .deny(reason: "hostname resolved to no addresses: \(host)")
            }
            for address in addresses {
                if let ipv4 = IPv4Address(address), isBlocked(ipv4: ipv4) {
                    return .deny(reason: "hostname \(host) resolved to blocked IPv4 \(address)")
                }
                if let ipv6 = IPv6Address.parse(address), isBlocked(ipv6: ipv6) {
                    return .deny(reason: "hostname \(host) resolved to blocked IPv6 \(address)")
                }
            }
        } catch {
            return .deny(reason: "DNS resolution failed for \(host): \(error.localizedDescription)")
        }

        if destination.port == 0 {
            return .deny(reason: "invalid port")
        }

        return .allow
    }

    private func isAllowedDomain(_ host: String) -> Bool {
        for suffix in allowedDomainSuffixes {
            if host == suffix || host.hasSuffix("." + suffix) {
                return true
            }
        }
        return false
    }

    private func isBlocked(ipv4: IPv4Address) -> Bool {
        blockedIPv4.contains { $0.contains(ipv4) }
    }

    private func isBlocked(ipv6: IPv6Address) -> Bool {
        blockedIPv6.contains { $0.contains(ipv6) }
    }
}

// MARK: - Minimal IP helpers

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
        let cleaned = string.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard inet_pton(AF_INET6, cleaned, &addr) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &addr) { Array($0.prefix(16)) }
        return IPv6Address(bytes: bytes)
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

struct IPv6Prefix {
    let network: [UInt8]
    let prefix: UInt8

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let ip = IPv6Address.parse(String(parts[0])),
              let prefix = UInt8(parts[1]),
              prefix <= 128 else { return nil }
        self.prefix = prefix
        self.network = ip.bytes
    }

    func contains(_ ip: IPv6Address) -> Bool {
        let bits = Int(prefix)
        let fullBytes = bits / 8
        let remBits = bits % 8
        let addr = ip.bytes
        guard addr.count == 16, network.count == 16 else { return false }
        if fullBytes > 0 {
            if Array(addr.prefix(fullBytes)) != Array(network.prefix(fullBytes)) {
                return false
            }
        }
        if remBits == 0 { return true }
        let mask = UInt8(0xFF << (8 - remBits))
        return (addr[fullBytes] & mask) == (network[fullBytes] & mask)
    }
}
