import Testing
@testable import EgressProxy

private struct StaticDNSResolver: DNSResolving {
    let addresses: [String: [String]]

    func resolveAddresses(for host: String) async throws -> [String] {
        addresses[host.lowercased()] ?? []
    }
}

@Suite struct EgressProxyTests {
    @Test func allowsGithubAPIWithPublicResolution() async {
        let policy = DefaultDestinationPolicy(
            resolver: StaticDNSResolver(addresses: [
                "api.github.com": ["140.82.112.6"]
            ])
        )
        let decision = await policy.evaluate(destination: ProxyDestination(host: "api.github.com", port: 443))
        #expect(decision == .allow)
    }

    @Test func deniesNonAllowlistedHost() async {
        let policy = DefaultDestinationPolicy(
            resolver: StaticDNSResolver(addresses: [
                "evil.example": ["93.184.216.34"]
            ])
        )
        let decision = await policy.evaluate(destination: ProxyDestination(host: "evil.example", port: 443))
        guard case .deny(let reason) = decision else {
            Issue.record("expected deny")
            return
        }
        #expect(reason.contains("allowlist"))
    }

    @Test func deniesHostDockerInternal() async {
        let policy = DefaultDestinationPolicy()
        let decision = await policy.evaluate(destination: ProxyDestination(host: "host.docker.internal", port: 8080))
        guard case .deny(let reason) = decision else {
            Issue.record("expected deny")
            return
        }
        #expect(reason.contains("blocked"))
    }

    @Test func deniesPrivateIPv4Literal() async {
        let policy = DefaultDestinationPolicy()
        let decision = await policy.evaluate(destination: ProxyDestination(host: "192.168.1.10", port: 80))
        guard case .deny(let reason) = decision else {
            Issue.record("expected deny")
            return
        }
        #expect(reason.contains("blocked") || reason.contains("not allowlisted"))
    }

    @Test func deniesAllowlistedHostResolvingToPrivateIP() async {
        let policy = DefaultDestinationPolicy(
            resolver: StaticDNSResolver(addresses: [
                "api.github.com": ["10.0.0.5"]
            ])
        )
        let decision = await policy.evaluate(destination: ProxyDestination(host: "api.github.com", port: 443))
        guard case .deny(let reason) = decision else {
            Issue.record("expected deny for DNS rebinding style private resolution")
            return
        }
        #expect(reason.contains("blocked IPv4"))
    }

    @Test func configurationExposesContainerProxyURL() {
        #expect(EgressProxyConfiguration.containerProxyURL.contains("host.docker.internal"))
        #expect(EgressProxyConfiguration.containerProxyURL.contains("\(EgressProxyConfiguration.listenPort)"))
        #expect(EgressProxyConfiguration.containerProxyEnvironment["HTTPS_PROXY"] != nil)
    }

    @Test func configurationDefaultsToLoopbackListenHost() {
        #expect(EgressProxyConfiguration.listenHost == "127.0.0.1")
    }

    @Test func listenParametersRequireConfiguredLocalEndpoint() {
        let parameters = EgressProxyListenBinding.tcpParameters(
            host: EgressProxyConfiguration.listenHost,
            port: EgressProxyConfiguration.listenPort
        )
        guard let endpoint = parameters.requiredLocalEndpoint else {
            Issue.record("expected requiredLocalEndpoint")
            return
        }
        let description = "\(endpoint)"
        #expect(description.contains("127.0.0.1"))
        #expect(description.contains("\(EgressProxyConfiguration.listenPort)"))
    }

    @Test func unauthorizedLoggerEmitsMessage() {
        final class Box: @unchecked Sendable {
            var messages: [String] = []
        }
        let box = Box()
        let logger = CallbackEgressProxyLogger { message in
            box.messages.append(message)
        }
        logger.logUnauthorizedAccess(
            destination: ProxyDestination(host: "10.0.0.1", port: 80),
            reason: "blocked",
            clientDescription: "test-client"
        )
        #expect(box.messages.contains { $0.contains("UNAUTHORIZED_EGRESS") })
        #expect(box.messages.contains { $0.contains("10.0.0.1:80") })
    }
}
