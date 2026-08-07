import Foundation
import DockerRunnerXPC
import ServiceContracts

final class JobServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try XPCPeerAuthentication.apply(
                requirement: XPCPeerAuthentication.requirementString(
                    allowedPeerIdentifiers: [
                        XPCPeerAuthentication.mainAppIdentifier,
                        XPCPeerAuthentication.agentServiceIdentifier,
                        XPCPeerAuthentication.webhookServiceIdentifier,
                        XPCPeerAuthentication.jobKeepAliveIdentifier
                    ]
                ),
                to: connection
            )
        } catch {
            fputs("[JobService] peer auth failed: \(error.localizedDescription)\n", stderr)
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: JobServiceXPC.self)
        connection.exportedObject = JobServiceExportedObject()
        connection.resume()
        fputs("[JobService] accepted connection\n", stderr)
        return true
    }
}
