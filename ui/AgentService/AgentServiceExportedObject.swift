import Foundation
import DBRepository
import ServiceContracts

/// Holds the live XPC connection so turn streaming can re-resolve the reverse sink.
final class AgentServiceConnectionContext: @unchecked Sendable {
    private let lock = NSLock()
    private weak var connection: NSXPCConnection?

    func attach(_ connection: NSXPCConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    /// Fresh reverse proxy with error logging (do not cache across process lifetime blindly).
    func clientSink(logLabel: String) -> AgentServiceClientSinkXPC? {
        lock.lock()
        let conn = connection
        lock.unlock()
        guard let conn else {
            fputs("[AgentService] \(logLabel): no connection for sink\n", stderr)
            return nil
        }
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            fputs(
                "[AgentService] \(logLabel): sink proxy error: \(error.localizedDescription)\n",
                stderr
            )
        }
        guard let sink = proxy as? AgentServiceClientSinkXPC else {
            fputs("[AgentService] \(logLabel): remote proxy not AgentServiceClientSinkXPC\n", stderr)
            return nil
        }
        return sink
    }
}

/// Health, ping, bootstrap, and turn hosting over XPC.
final class AgentServiceExportedObject: NSObject, AgentServiceXPC {
    let connectionContext = AgentServiceConnectionContext()

    func bind(connection: NSXPCConnection) {
        connectionContext.attach(connection)
        AgentServiceLogRelay.shared.attach(connection: connection)
        connection.invalidationHandler = { [weak connection] in
            if let connection {
                AgentServiceLogRelay.shared.detach(connection: connection)
            }
        }
    }

    func health(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            await AgentServiceStore.shared.log(level: .debug, message: "health requested", code: "health")
            let path = await AgentServiceStore.shared.databasePath()
            let leaf = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
            let report = ServiceHealthReport(
                service: .agent,
                status: .ok,
                detail: "AgentService ready (DB+\(leaf))"
            )
            let data = (try? AgentServiceXPCCodec.encodeHealth(report)) ?? Data("{}".utf8)
            reply(data as NSData)
        }
    }

    func ping(payload: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let payloadData = payload as Data
        Task {
            let text = AgentServiceXPCCodec.decodeString(payloadData)
            let snippet = String(text.prefix(80))
            await AgentServiceStore.shared.log(
                level: .debug,
                message: "ping",
                code: "ping",
                detailJSON: #"{"payload":"\#(snippet)"}"#
            )
            let response = AgentServiceXPCCodec.encodeString("pong:\(text)")
            reply(response as NSData)
        }
    }

    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let repo = try await AgentServiceStore.shared.sharedRepository()
                let path = await repo.databaseURL.path
                try await repo.appendServiceLog(
                    ServiceLogEntry(
                        service: DerrickServiceID.agent.shortName,
                        level: .info,
                        code: "bootstrap",
                        message: "AgentService bootstrap complete",
                        detailJSON: #"{"database":"\#(path)"}"#
                    )
                )
                let result = AgentServiceBootstrapResult(ok: true, databasePath: path, message: "ok")
                let data = try AgentServiceXPCCodec.encodeBootstrap(result)
                reply(data as NSData)
            } catch {
                let message = error.localizedDescription
                await AgentServiceStore.shared.log(
                    level: .error,
                    message: "bootstrap failed: \(message)",
                    code: "bootstrap_failed"
                )
                let result = AgentServiceBootstrapResult(
                    ok: false,
                    databasePath: nil,
                    message: message
                )
                let data = (try? AgentServiceXPCCodec.encodeBootstrap(result)) ?? Data("{}".utf8)
                reply(data as NSData)
            }
        }
    }

    func setMCPServicePeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping @Sendable (NSData) -> Void
    ) {
        // System invariant: handoff is not complete until Agent can RPC MCPService.
        Task {
            do {
                MCPServiceClient.shared.installPeerEndpoint(endpoint)
                try await MCPServiceClient.shared.verifyPeerMesh()
                await AgentServiceStore.shared.log(
                    level: .info,
                    message: "MCPService peer mesh verified (Agent→MCP searchTools ok)",
                    code: "mcp_peer_mesh_ok"
                )
                fputs("[AgentService] MCPService peer mesh verified\n", stderr)
                reply(AgentServiceXPCCodec.encodeString("ok") as NSData)
            } catch {
                let message = error.localizedDescription
                await AgentServiceStore.shared.log(
                    level: .error,
                    message: "MCPService peer mesh failed: \(message)",
                    code: "mcp_peer_mesh_failed"
                )
                fputs("[AgentService] MCPService peer mesh failed: \(message)\n", stderr)
                reply(AgentServiceXPCCodec.encodeString("error:\(message)") as NSData)
            }
        }
    }

    func startTurn(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        let context = connectionContext
        Task {
            do {
                let request = try AgentServiceXPCCodec.decodeTurnRequest(data)
                // Probe sink before starting so we log nil early.
                let probe = context.clientSink(logLabel: "startTurn")
                fputs(
                    "[AgentService] startTurn id=\(request.turnID) sink=\(probe != nil)\n",
                    stderr
                )
                let accepted = await AgentServiceTurnHost.shared.startTurn(
                    request: request,
                    connectionContext: context
                )
                let response = try AgentServiceXPCCodec.encodeTurnAccepted(accepted)
                reply(response as NSData)
            } catch {
                let accepted = AgentTurnAccepted(
                    ok: false,
                    turnID: "",
                    sessionID: "",
                    message: error.localizedDescription
                )
                let response = (try? AgentServiceXPCCodec.encodeTurnAccepted(accepted)) ?? Data("{}".utf8)
                reply(response as NSData)
            }
        }
    }

    func cancelTurn(turnID: String, withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            await AgentServiceTurnHost.shared.cancelTurn(turnID: turnID)
            await AgentServiceStore.shared.log(
                level: .info,
                message: "cancelTurn \(turnID)",
                code: "turn_cancel"
            )
            reply(AgentServiceXPCCodec.encodeString("ok") as NSData)
        }
    }
}
