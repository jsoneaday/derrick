import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Anonymous XPC peer listener so AgentService can call JobService.
/// Endpoint is handed to the UI over Application XPC (`peerListenerEndpoint`),
/// then UI forwards it to AgentService. Endpoints only encode via NSXPCCoder.
final class JobServicePeerEndpoint: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let shared = JobServicePeerEndpoint()

    private let lock = NSLock()
    private var peerListener: NSXPCListener?
    private let exportedObject = JobServiceExportedObject()

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
            fputs("[JobService] peer listener started\n", stderr)
        }
        return peerListener!.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if XPCPeerAuthentication.isDebugMode() {
            fputs("[JobService] peer code-signing requirement skipped because IS_DEBUG=true\n", stderr)
        } else {
            do {
                try XPCPeerAuthentication.apply(.jobAcceptingAgentAndMCP, to: connection)
            } catch {
                fputs("[JobService] peer auth failed: \(error.localizedDescription)\n", stderr)
                return false
            }
        }

        let exported = NSXPCInterface(with: JobServiceXPC.self)
        let endpointClasses = NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>
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
        connection.exportedObject = exportedObject
        connection.resume()
        fputs("[JobService] peer accepted connection pid=\(connection.processIdentifier)\n", stderr)
        return true
    }
}
