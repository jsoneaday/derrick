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

        let exported = NSXPCInterface(with: JobServiceXPC.self)
        let endpointClasses = NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>
        // peerListenerEndpoint reply is NSXPCListenerEndpoint
        exported.setClasses(
            endpointClasses,
            for: #selector(JobServiceXPC.peerListenerEndpoint(authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        exported.setClasses(
            endpointClasses,
            for: #selector(JobServiceXPC.setMCPServicePeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        exported.setClasses(
            endpointClasses,
            for: #selector(JobServiceXPC.setAgentServicePeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.exportedInterface = exported
        connection.exportedObject = JobServiceExportedObject()
        connection.resume()
        fputs("[JobService] accepted connection\n", stderr)
        return true
    }
}
