import Foundation
import DockerRunnerXPC

/// Anonymous XPC peer listener so MCPService can call DockerRunnerHelper.
/// Endpoint is handed to the UI over Application XPC (`peerListenerEndpoint`),
/// then UI forwards it to MCPService. Endpoints only encode via NSXPCCoder.
///
/// Peer connections export process-runner RPCs only — they do **not** attach
/// `HelperLogRelay` / mid-flight egress sink. The UI’s serviceName connection
/// remains the sole reverse channel for prompts and helper logs.
final class DockerHelperPeerEndpoint: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let shared = DockerHelperPeerEndpoint()

    private let lock = NSLock()
    private var peerListener: NSXPCListener?

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
            HelperLogRelay.shared.log("Docker helper peer listener started")
        }
        return peerListener!.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Anonymous peer mesh (MCPService). Do not setCodeSigningRequirement here:
        // Debug ad-hoc signing + anonymous endpoints fail closed and break the mesh.
        // Application XPC (UI→helper serviceName) still uses peer auth on the service listener.
        connection.exportedInterface = NSXPCInterface(with: DockerProcessRunnerXPC.self)
        connection.exportedObject = DockerRunnerService()
        // No remoteObjectInterface / HelperLogRelay.attach — keep UI as sole egress prompt sink.
        connection.interruptionHandler = {
            HelperLogRelay.shared.log("Docker helper peer connection interrupted")
        }
        connection.invalidationHandler = {
            HelperLogRelay.shared.log("Docker helper peer connection invalidated")
        }
        connection.resume()
        HelperLogRelay.shared.log(
            "Docker helper peer accepted connection pid=\(connection.processIdentifier)"
        )
        return true
    }
}
