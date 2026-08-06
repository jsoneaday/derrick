import Foundation
import DockerRunnerXPC
import ServiceContracts

final class AgentServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try XPCPeerAuthentication.apply(
                requirement: XPCPeerAuthentication.requirementString(
                    allowedPeerIdentifiers: [
                        XPCPeerAuthentication.mainAppIdentifier,
                        XPCPeerAuthentication.jobServiceIdentifier
                    ]
                ),
                to: connection
            )
        } catch {
            fputs("[AgentService] peer auth failed: \(error.localizedDescription)\n", stderr)
            return false
        }

        let exported = AgentServiceExportedObject()
        let exportedInterface = NSXPCInterface(with: AgentServiceXPC.self)
        exportedInterface.setClasses(
            NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>,
            for: #selector(AgentServiceXPC.setMCPServicePeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.exportedInterface = exportedInterface
        connection.exportedObject = exported
        // Reverse channel: UI exports AgentServiceClientSinkXPC.
        connection.remoteObjectInterface = NSXPCInterface(with: AgentServiceClientSinkXPC.self)
        exported.bind(connection: connection)
        connection.resume()
        fputs("[AgentService] accepted connection\n", stderr)
        return true
    }
}

