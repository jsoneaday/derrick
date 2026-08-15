import Foundation
import DockerRunnerXPC
import ServiceContracts

/// NSXPC export for `DerrickDaemonXPC`.
public final class DaemonExportedObject: NSObject, DerrickDaemonXPC, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func health(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            let report = await DaemonRuntime.shared.health()
            let data = (try? DerrickDaemonXPCCodec.encodeHealth(report)) ?? Data()
            reply(data as NSData)
        }
    }

    public func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void) {
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

    public func retire(withReply reply: @escaping @Sendable (NSData) -> Void) {
        let ack = ServiceAckDTO(ok: true, message: "retiring")
        reply((try? DerrickDaemonXPCCodec.encodeAck(ack)) as NSData? ?? Data() as NSData)
        DaemonSelfRetirement.requestExit(reason: "XPC retire")
    }

    public func postUserNotification(
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

    public func listEgressBlacklist(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let result = try await DaemonRuntime.shared.listEgressBlacklist()
                reply((try DerrickDaemonXPCCodec.encodeBlacklistList(result)) as NSData)
            } catch {
                reply(Data() as NSData)
            }
        }
    }

    public func addEgressBlacklist(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        nonisolated(unsafe) let payload = requestJSON as Data
        Task {
            do {
                let request = try DerrickDaemonXPCCodec.decodeBlacklistAddRequest(payload)
                try await DaemonRuntime.shared.addEgressBlacklist(pattern: request.pattern)
                reply((try DerrickDaemonXPCCodec.encodeAck(.ok)) as NSData)
            } catch {
                let ack = ServiceAckDTO.error(error.localizedDescription)
                reply((try? DerrickDaemonXPCCodec.encodeAck(ack)) as NSData? ?? Data() as NSData)
            }
        }
    }

    public func removeEgressBlacklist(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        nonisolated(unsafe) let payload = requestJSON as Data
        Task {
            do {
                let request = try DerrickDaemonXPCCodec.decodeBlacklistRemoveRequest(payload)
                try await DaemonRuntime.shared.removeEgressBlacklist(id: request.id)
                reply((try DerrickDaemonXPCCodec.encodeAck(.ok)) as NSData)
            } catch {
                let ack = ServiceAckDTO.error(error.localizedDescription)
                reply((try? DerrickDaemonXPCCodec.encodeAck(ack)) as NSData? ?? Data() as NSData)
            }
        }
    }
}

/// Mach-service listener for the Daemon LaunchAgent.
public final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: DerrickDaemonXPC.self)
        newConnection.exportedObject = DaemonExportedObject()
        do {
            try XPCPeerAuthentication.apply(
                requirement: XPCPeerAuthentication.requirementString(
                    allowedPeerIdentifiers: [
                        DerrickServiceID.ui.rawValue,
                        // Temporary: legacy XPC services may forward notify during migration.
                        DerrickServiceID.agent.rawValue,
                        DerrickServiceID.job.rawValue,
                        DerrickServiceID.mcp.rawValue
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
