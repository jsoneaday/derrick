import Foundation
import EgressProxy

/// Starts the local egress proxy inside the privileged helper and relays logs to the app.
enum EgressProxyBootstrap {
    /// Shared policy instance so XPC can update the allowlist at runtime.
    static let policy = DefaultDestinationPolicy(allowedDomainSuffixes: [])

    private static let server = EgressProxyServer(
        policy: policy,
        logger: MultiplexEgressProxyLogger(sinks: [
            OSLogEgressProxyLogger(subsystem: "derrick.ui.DockerRunnerHelper", category: "EgressProxy"),
            CallbackEgressProxyLogger { message in
                HelperLogRelay.shared.log(message)
            }
        ])
    )

    static func startIfNeeded() {
        Task {
            do {
                if await server.isRunning {
                    return
                }
                try await server.start()
                let port = await server.listenPort
                HelperLogRelay.shared.log(
                    "EgressProxy listening on \(EgressProxyConfiguration.listenHost):\(port)"
                )
            } catch {
                HelperLogRelay.shared.log(
                    "EgressProxy failed to start: \(error.localizedDescription)"
                )
            }
        }
    }

    static func setAllowedDomainSuffixes(_ suffixes: [String]) {
        policy.setAllowedDomainSuffixes(suffixes)
        HelperLogRelay.shared.log(
            "EgressProxy allowlist updated (\(suffixes.count) suffix(es))"
        )
    }

    static func grantSessionHosts(_ hosts: [String]) {
        policy.grantSessionHosts(hosts)
        HelperLogRelay.shared.log(
            "EgressProxy session grants: \(hosts.joined(separator: ", "))"
        )
    }
}
