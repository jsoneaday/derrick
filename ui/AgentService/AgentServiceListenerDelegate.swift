import Foundation
import DockerRunnerXPC
import Structure

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
        let endpointClasses = NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>
        exportedInterface.setClasses(
            endpointClasses,
            for: #selector(AgentServiceXPC.peerListenerEndpoint(authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        exportedInterface.setClasses(
            endpointClasses,
            for: #selector(AgentServiceXPC.setMCPServicePeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        exportedInterface.setClasses(
            endpointClasses,
            for: #selector(AgentServiceXPC.setJobServicePeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.exportedInterface = exportedInterface
        connection.exportedObject = exported
        // Reverse channel: UI exports AgentServiceClientSinkXPC.
        connection.remoteObjectInterface = NSXPCInterface(with: AgentServiceClientSinkXPC.self)
        exported.bind(connection: connection)
        // Remember UI reverse channel so job-sourced wakes can stream into the chat UI.
        AgentServicePrimaryUISink.shared.attach(connection: connection)
        connection.resume()
        fputs("[AgentService] accepted connection\n", stderr)
        return true
    }
}

