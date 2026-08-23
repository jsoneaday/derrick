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
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard EgressHostExtractor.isPlausibleHostname(normalizedHost) else {
            throw WebCrawlerProxyError.invalidHost
        }

        let suffix = EgressHostExtractor.permanentSuffix(for: normalizedHost)
        activeSuffixes[suffix, default: 0] += 1
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
            releaseSuffix(suffix)
            throw error
        }

        return WebCrawlerProxyLease(
            host: Self.containerProxyHost,
            port: Self.containerProxyPort,
            clientToken: clientToken
        )
    }

    public func release(for host: String) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffix = EgressHostExtractor.permanentSuffix(for: normalizedHost)
        releaseSuffix(suffix)
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
