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
        // Anonymous peer mesh (Agent/Job/Webhook). Do not setCodeSigningRequirement here:
        // Debug ad-hoc signing + anonymous endpoints fail closed and break the mesh.
        // Application XPC (UI→MCP serviceName) still uses peer auth on the service listener.
        let exportedInterface = NSXPCInterface(with: MCPServiceXPC.self)
        exportedInterface.setClasses(
            NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>,
            for: #selector(MCPServiceXPC.setDockerHelperPeerEndpoint(_:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.exportedInterface = exportedInterface
        connection.exportedObject = exportedObject
        connection.resume()
        fputs("[MCPService] peer accepted connection pid=\(connection.processIdentifier)\n", stderr)
        return true
    }
}
