import Darwin
import Foundation
import EgressProxy

/// Starts the local egress proxy inside the privileged helper and relays logs to the app.
enum EgressProxyBootstrap {
    /// Shared policy instance so XPC can update the allowlist at runtime.
    /// Mid-flight unknown hosts prompt the app via reverse XPC (once/always/deny).
    static let policy: DefaultDestinationPolicy = {
        let reverseXPC = ClosureHostAccessPrompter { host in
            await HelperLogRelay.shared.requestEgressHostAccess(host: host)
        }
        // Coalesce concurrent CONNECTs to the same host + 120s timeout.
        let coalesced = CoalescingHostAccessPrompterBox(underlying: reverseXPC, timeoutSeconds: 120)
        return DefaultDestinationPolicy(
            allowedDomainSuffixes: [],
            hostAccessPrompter: coalesced
        )
    }()

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
                if isAddressAlreadyInUse(error),
                   isLoopbackPortOpen(
                    host: EgressProxyConfiguration.listenHost,
                    port: EgressProxyConfiguration.listenPort
                   ) {
                    HelperLogRelay.shared.log(
                        "EgressProxy already listening on \(EgressProxyConfiguration.listenHost):\(EgressProxyConfiguration.listenPort) — reusing existing listener"
                    )
                    return
                }
                HelperLogRelay.shared.log(
                    "EgressProxy failed to start: \(error.localizedDescription)"
                )
            }
        }
    }

    static func setAllowedDomainSuffixes(_ suffixes: [String]) {
        // Replacing the permanent list also drops session grants so removals in Settings
        // cannot be shadowed by a prior "Allow once" / mid-flight grant in this helper.
        policy.setAllowedDomainSuffixes(suffixes)
        policy.clearSessionHosts()
        HelperLogRelay.shared.log(
            "EgressProxy allowlist updated (\(suffixes.count) suffix(es)); session grants cleared"
        )
    }

    static func grantSessionHosts(_ hosts: [String]) {
        policy.grantSessionHosts(hosts)
        HelperLogRelay.shared.log(
            "EgressProxy session grants: \(hosts.joined(separator: ", "))"
        )
    }

    // MARK: - Port probe

    private static func isAddressAlreadyInUse(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        if text.contains("address already in use") { return true }
        if text.contains("error 48") { return true }
        if case EgressProxyError.listenerFailed(let message) = error {
            return isAddressAlreadyInUseMessage(message)
        }
        return false
    }

    private static func isAddressAlreadyInUseMessage(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("address already in use") || text.contains("error 48")
    }

    private static func isLoopbackPortOpen(host: String, port: UInt16) -> Bool {
        guard port > 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            return false
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
