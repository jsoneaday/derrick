import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Anonymous XPC peer listener so JobService can call AgentService (wakeAgent / startTurn).
/// Endpoint is handed to the UI over Application XPC (`peerListenerEndpoint`),
/// then UI forwards it to JobService.
final class AgentServicePeerEndpoint: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let shared = AgentServicePeerEndpoint()

    private let lock = NSLock()
    private var peerListener: NSXPCListener?
    private let exportedObject = AgentServiceExportedObject()
    private let peerSink = AgentServicePeerSilentSink()

    private override init() {
        super.init()
    }

    func endpointForHandoff() -> NSXPCListenerEndpoint {
        lock.lock()
        defer { lock.unlock() }
        if peerListener == nil {
            let listener = NSXPCListener.anonymous()
            listener.delegate = self
            listener.resume()
            peerListener = listener
            fputs("[AgentService] peer listener started\n", stderr)
        }
        return peerListener!.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Anonymous peer mesh (JobService). No code-sign requirement.
        let exportedInterface = NSXPCInterface(with: AgentServiceXPC.self)
        let endpointClasses = NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>
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
        connection.exportedObject = exportedObject
        // JobService exports a sink; accept reverse channel.
        connection.remoteObjectInterface = NSXPCInterface(with: AgentServiceClientSinkXPC.self)
        // Bind a no-op sink context if Job does not export — JobAgentClient does export sink.
        exportedObject.bind(connection: connection)
        connection.resume()
        fputs("[AgentService] peer accepted connection pid=\(connection.processIdentifier)\n", stderr)
        return true
    }
}

/// Placeholder type kept so peer module compiles if needed for future reverse RPCs.
private final class AgentServicePeerSilentSink: NSObject, AgentServiceClientSinkXPC {
    func appendServiceLogLine(_ line: String) {}
    func turnDidEmitChunk(_ turnID: String, chunkJSON: NSData) {}
    func turnDidFinish(_ turnID: String, errorJSON: NSData) {}
    func requestApproval(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        reply(Data() as NSData)
    }
    func requestNetworkAccess(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        reply(Data() as NSData)
    }
    func presentJobResult(_ resultJSON: NSData) {}
}
