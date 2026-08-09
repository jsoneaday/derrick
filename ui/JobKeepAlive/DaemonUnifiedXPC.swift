import Foundation
import DockerRunnerXPC
import DerrickBackend
import ServiceContracts

/// Unified Mach-XPC export: UI talks only to derrickd; Agent/Job/MCP run in-process.
final class DaemonUnifiedExportedObject: NSObject, DerrickDaemonServiceXPC, @unchecked Sendable {
    private let agent = AgentServiceExportedObject()
    private let job = JobServiceExportedObject()
    private let mcp = MCPServiceExportedObject()

    func bind(connection: NSXPCConnection) {
        agent.bind(connection: connection)
    }

    // MARK: - Shared / daemon

    func health(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            let report = await DaemonRuntime.shared.health()
            let data = (try? DerrickDaemonXPCCodec.encodeHealth(report)) ?? Data()
            reply(data as NSData)
        }
    }

    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let result = try await DaemonRuntime.shared.bootstrap()
                let data = try DerrickDaemonXPCCodec.encodeBootstrap(result)
                reply(data as NSData)
            } catch {
                let fail = DerrickDaemonBootstrapResult(ok: false, message: error.localizedDescription)
                let data = (try? DerrickDaemonXPCCodec.encodeBootstrap(fail)) ?? Data()
                reply(data as NSData)
            }
        }
    }

    func postUserNotification(
        requestJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    ) {
        nonisolated(unsafe) let payload = requestJSON as Data
        Task {
            do {
                let request = try DerrickDaemonXPCCodec.decodeNotificationRequest(payload)
                try await DaemonRuntime.shared.postNotification(request)
                let ack = ServiceAckDTO(ok: true, message: "posted")
                reply((try DerrickDaemonXPCCodec.encodeAck(ack)) as NSData)
            } catch {
                let ack = ServiceAckDTO(ok: false, message: error.localizedDescription)
                reply((try? DerrickDaemonXPCCodec.encodeAck(ack)) as NSData? ?? Data() as NSData)
            }
        }
    }

    // MARK: - Agent

    func ping(payload: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        agent.ping(payload: payload, withReply: reply)
    }

    func peerListenerEndpoint(authJSON: NSData, withReply reply: @escaping @Sendable (NSXPCListenerEndpoint) -> Void) {
        // Prefer Agent peer when auth targets agent; otherwise job/mcp based on kind.
        do {
            let auth = try? AgentServiceXPCCodec.decodeSignedPeerHandoffAuth(
                authJSON as Data,
                expectedTo: .agent,
                expectedKind: .fetchAgentPeer
            )
            if auth != nil {
                agent.peerListenerEndpoint(authJSON: authJSON, withReply: reply)
                return
            }
        }
        do {
            let auth = try? JobServiceXPCCodec.decodeSignedPeerHandoffAuth(
                authJSON as Data,
                expectedTo: .job,
                expectedKind: .fetchJobPeer
            )
            if auth != nil {
                job.peerListenerEndpoint(authJSON: authJSON, withReply: reply)
                return
            }
        }
        mcp.peerListenerEndpoint(authJSON: authJSON, withReply: reply)
    }

    func setMCPServicePeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        authJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    ) {
        // Agent and Job share this selector; dispatch on auth kind.
        if (try? AgentServiceXPCCodec.decodeSignedPeerHandoffAuth(
            authJSON as Data,
            expectedTo: .agent,
            expectedKind: .installMCPPeer
        )) != nil {
            agent.setMCPServicePeerEndpoint(endpoint, authJSON: authJSON, withReply: reply)
            return
        }
        job.setMCPServicePeerEndpoint(endpoint, authJSON: authJSON, withReply: reply)
    }

    func setJobServicePeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        authJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    ) {
        agent.setJobServicePeerEndpoint(endpoint, authJSON: authJSON, withReply: reply)
    }

    func startTurn(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        agent.startTurn(requestJSON: requestJSON, withReply: reply)
    }

    func cancelTurn(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        agent.cancelTurn(requestJSON: requestJSON, withReply: reply)
    }

    // MARK: - Job

    func setAgentServicePeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        authJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    ) {
        job.setAgentServicePeerEndpoint(endpoint, authJSON: authJSON, withReply: reply)
    }

    func createJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.createJob(requestJSON: requestJSON, withReply: reply)
    }

    func cancelJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.cancelJob(requestJSON: requestJSON, withReply: reply)
    }

    func getJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.getJob(requestJSON: requestJSON, withReply: reply)
    }

    func listJobs(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.listJobs(requestJSON: requestJSON, withReply: reply)
    }

    func createSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.createSchedule(requestJSON: requestJSON, withReply: reply)
    }

    func updateSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.updateSchedule(requestJSON: requestJSON, withReply: reply)
    }

    func setScheduleEnabled(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.setScheduleEnabled(requestJSON: requestJSON, withReply: reply)
    }

    func deleteSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.deleteSchedule(requestJSON: requestJSON, withReply: reply)
    }

    func getSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.getSchedule(requestJSON: requestJSON, withReply: reply)
    }

    func listSchedules(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        job.listSchedules(requestJSON: requestJSON, withReply: reply)
    }

    // MARK: - MCP

    func setDockerHelperPeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        authJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    ) {
        mcp.setDockerHelperPeerEndpoint(endpoint, authJSON: authJSON, withReply: reply)
    }

    func callTool(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        mcp.callTool(requestJSON: requestJSON, withReply: reply)
    }

    func searchTools(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        mcp.searchTools(requestJSON: requestJSON, withReply: reply)
    }
}

final class DaemonUnifiedListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let exported = DaemonUnifiedExportedObject()
        let exportedInterface = NSXPCInterface(with: DerrickDaemonServiceXPC.self)
        let endpointClasses = NSSet(array: [NSXPCListenerEndpoint.self]) as! Set<AnyHashable>
        exportedInterface.setClasses(
            endpointClasses,
            for: #selector(DerrickDaemonServiceXPC.peerListenerEndpoint(authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        exportedInterface.setClasses(
            endpointClasses,
            for: #selector(DerrickDaemonServiceXPC.setMCPServicePeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        exportedInterface.setClasses(
            endpointClasses,
            for: #selector(DerrickDaemonServiceXPC.setJobServicePeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        exportedInterface.setClasses(
            endpointClasses,
            for: #selector(DerrickDaemonServiceXPC.setAgentServicePeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        exportedInterface.setClasses(
            endpointClasses,
            for: #selector(DerrickDaemonServiceXPC.setDockerHelperPeerEndpoint(_:authJSON:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.exportedInterface = exportedInterface
        newConnection.exportedObject = exported
        newConnection.remoteObjectInterface = NSXPCInterface(with: AgentServiceClientSinkXPC.self)
        exported.bind(connection: newConnection)
        AgentServicePrimaryUISink.shared.attach(connection: newConnection)

        do {
            try XPCPeerAuthentication.apply(
                requirement: XPCPeerAuthentication.requirementString(
                    allowedPeerIdentifiers: [
                        DerrickServiceID.ui.rawValue,
                        DerrickServiceID.dockerHelper.rawValue
                    ]
                ),
                to: newConnection
            )
        } catch {
            fputs("[derrickd] peer auth soft-fail: \(error.localizedDescription)\n", stderr)
        }
        newConnection.invalidationHandler = {
            fputs("[derrickd] client connection invalidated\n", stderr)
        }
        newConnection.resume()
        return true
    }
}
