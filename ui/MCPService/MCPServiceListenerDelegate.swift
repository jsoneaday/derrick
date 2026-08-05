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

        let exportedInterface = NSXPCInterface(with: MCPServiceXPC.self)
        exportedInterface.setClasses(
            NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>,
            for: #selector(MCPServiceXPC.setDockerHelperPeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.exportedInterface = exportedInterface
        connection.exportedObject = MCPServiceExportedObject()
        connection.resume()
        fputs("[MCPService] accepted connection\n", stderr)
        return true
    }
}
