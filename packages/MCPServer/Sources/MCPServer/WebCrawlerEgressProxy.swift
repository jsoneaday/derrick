import EgressProxy
import Foundation

public struct WebCrawlerProxyLease: Sendable, Hashable {
    public let host: String
    public let port: Int
    public let clientToken: String

    public init(host: String, port: Int, clientToken: String) {
        self.host = host
        self.port = port
        self.clientToken = clientToken
    }
}

/// Owns the existing host egress proxy for crawler containers.
///
/// The proxy stays on the host while the MCP service is alive. Each active
/// crawl leases its start-domain suffix, and the policy allows only suffixes
/// belonging to active leases. Containers authenticate with the private token.
public actor WebCrawlerEgressProxy {
    public static let shared = WebCrawlerEgressProxy()

    public static let containerProxyHost = "host.docker.internal"
    public static let containerProxyPort = Int(EgressProxyConfiguration.listenPort)

    private let policy = DefaultDestinationPolicy(allowedDomainSuffixes: [])
    private let clientToken = UUID().uuidString.lowercased()
    private var server: EgressProxyServer?
    private var activeSuffixes: [String: Int] = [:]

    public init() {}

    public func lease(for host: String) async throws -> WebCrawlerProxyLease {
        try await lease(forHosts: [host])
    }

    public func lease(forHosts hosts: [String]) async throws -> WebCrawlerProxyLease {
        let normalizedHosts = hosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalizedHosts.isEmpty else {
            throw WebCrawlerProxyError.invalidHost
        }
        for host in normalizedHosts {
            guard EgressHostExtractor.isPlausibleHostname(host) else {
                throw WebCrawlerProxyError.invalidHost
            }
        }

        let suffixes = Set(normalizedHosts.map { EgressHostExtractor.permanentSuffix(for: $0) })
        for suffix in suffixes {
            activeSuffixes[suffix, default: 0] += 1
        }
        policy.setAllowedDomainSuffixes(activeSuffixes.keys.sorted())

        do {
            if server == nil {
                let proxy = EgressProxyServer(
                    policy: policy,
                    listenHost: EgressProxyConfiguration.dockerWorkerListenHost,
                    listenPort: EgressProxyConfiguration.listenPort,
                    requiredClientToken: clientToken
                )
                try await proxy.start()
                server = proxy
            }
        } catch {
            for suffix in suffixes {
                releaseSuffix(suffix)
            }
            throw error
        }

        return WebCrawlerProxyLease(
            host: Self.containerProxyHost,
            port: Self.containerProxyPort,
            clientToken: clientToken
        )
    }

    public func release(for host: String) {
        release(forHosts: [host])
    }

    public func release(forHosts hosts: [String]) {
        let suffixes = Set(
            hosts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
                .map { EgressHostExtractor.permanentSuffix(for: $0) }
        )
        for suffix in suffixes {
            releaseSuffix(suffix)
        }
    }

    private func releaseSuffix(_ suffix: String) {
        if let count = activeSuffixes[suffix], count > 1 {
            activeSuffixes[suffix] = count - 1
        } else {
            activeSuffixes[suffix] = nil
        }
        policy.setAllowedDomainSuffixes(activeSuffixes.keys.sorted())
    }
}

public enum WebCrawlerProxyError: Error, LocalizedError, Sendable, Equatable {
    case invalidHost

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Crawler proxy lease requested for an invalid hostname."
        }
    }
}
