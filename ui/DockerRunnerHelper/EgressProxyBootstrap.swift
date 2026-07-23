import Foundation
import EgressProxy

/// Starts the local egress proxy inside the privileged helper and relays logs to the app.
enum EgressProxyBootstrap {
    private static let server = EgressProxyServer(
        policy: DefaultDestinationPolicy(),
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
}
