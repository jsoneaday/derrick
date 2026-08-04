import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Anonymous XPC peer listener so AgentService can call MCPService.
/// Endpoint is handed to the UI over the Application XPC channel (`peerListenerEndpoint`),
/// then UI forwards it to AgentService over Agent XPC. Endpoints only encode via NSXPCCoder.
final class MCPServicePeerEndpoint: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let shared = MCPServicePeerEndpoint()

    private let lock = NSLock()
    private var peerListener: NSXPCListener?
    private let exportedObject = MCPServiceExportedObject()

    private override init() {
        super.init()
    }

    /// Ensure peer listener is running; return its endpoint for XPC transfer.
    func endpointForHandoff() -> NSXPCListenerEndpoint {
        lock.lock()
        defer { lock.unlock() }
        if peerListener == nil {
            let listener = NSXPCListener.anonymous()
            listener.delegate = self
            listener.resume()
            peerListener = listener
            fputs("[MCPService] peer listener started\n", stderr)
        }
        return peerListener!.endpoint
    }

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
            fputs("[MCPService] peer auth soft-fail (continuing): \(error.localizedDescription)\n", stderr)
        }
        connection.exportedInterface = NSXPCInterface(with: MCPServiceXPC.self)
        connection.exportedObject = exportedObject
        connection.resume()
        fputs("[MCPService] peer accepted connection pid=\(connection.processIdentifier)\n", stderr)
        return true
    }
}
