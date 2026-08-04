import Foundation
import DockerRunnerXPC
import ServiceContracts

final class MCPServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try XPCPeerAuthentication.apply(
                requirement: XPCPeerAuthentication.requirementString(
                    allowedPeerIdentifiers: [
                        XPCPeerAuthentication.mainAppIdentifier,
                        XPCPeerAuthentication.agentServiceIdentifier,
                        XPCPeerAuthentication.jobServiceIdentifier,
                        XPCPeerAuthentication.webhookServiceIdentifier
                    ]
                ),
                to: connection
            )
        } catch {
            fputs("[MCPService] peer auth failed: \(error.localizedDescription)\n", stderr)
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: MCPServiceXPC.self)
        connection.exportedObject = MCPServiceExportedObject()
        connection.resume()
        fputs("[MCPService] accepted connection\n", stderr)
        return true
    }
}
