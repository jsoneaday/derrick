import Foundation
import DBRepository
import ServiceContracts

final class MCPServiceExportedObject: NSObject, MCPServiceXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            await MCPServiceStore.shared.log(level: .debug, message: "health requested", code: "health")
            let path = await MCPServiceStore.shared.databasePath()
            let leaf = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
            let report = ServiceHealthReport(
                service: .mcp,
                status: .ok,
                detail: "MCPService ready (DB+\(leaf))"
            )
            let data = (try? MCPServiceXPCCodec.encodeHealth(report)) ?? Data("{}".utf8)
            reply(data as NSData)
        }
    }

    func ping(payload: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let ping = try MCPServiceXPCCodec.decodeSignedPing(payload as Data, expectedTo: .mcp)
                await MCPServiceStore.shared.log(level: .debug, message: "ping", code: "ping")
                let response = try MCPServiceXPCCodec.encodeSignedPing(
                    "pong:\(ping.text)",
                    from: .mcp,
                    to: .ui
                )
                reply(response as NSData)
            } catch {
                fputs("[MCPService] ping failed: \(error.localizedDescription)\n", stderr)
                reply(Data() as NSData)
            }
        }
    }

    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let repo = try await MCPServiceStore.shared.sharedRepository()
                await ContainerLifecycleSettingsService.shared.configure(repository: repo)
                await OrchestrationLimitsSettingsService.shared.configure(repository: repo)
                await SoftwareFactorySettingsService.shared.configure(repository: repo)
                _ = try await MCPServiceToolHost.shared.ensureReady()
                _ = MCPServicePeerEndpoint.shared.endpointForHandoff()
                let path = await repo.databaseURL.path
                try await repo.appendServiceLog(
                    ServiceLogEntry(
                        service: DerrickServiceID.mcp.shortName,
                        level: .info,
                        code: "bootstrap",
                        message: "MCPService bootstrap complete",
                        detailJSON: #"{"database":"\#(path)"}"#
                    )
                )
                let result = MCPServiceBootstrapResult(ok: true, databasePath: path, message: "ok")
                reply((try MCPServiceXPCCodec.encodeBootstrap(result)) as NSData)
            } catch {
                await MCPServiceStore.shared.log(
                    level: .error,
                    message: "bootstrap failed: \(error.localizedDescription)",
                    code: "bootstrap_failed"
                )
                let result = MCPServiceBootstrapResult(
                    ok: false,
                    databasePath: nil,
                    message: error.localizedDescription
                )
                reply((try? MCPServiceXPCCodec.encodeBootstrap(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    func peerListenerEndpoint(authJSON: NSData, withReply reply: @escaping @Sendable (NSXPCListenerEndpoint) -> Void) {
        do {
            _ = try MCPServiceXPCCodec.decodeSignedPeerHandoffAuth(
                authJSON as Data,
                expectedTo: .mcp,
                expectedKind: .fetchMCPPeer
            )
            let endpoint = MCPServicePeerEndpoint.shared.endpointForHandoff()
            fputs("[MCPService] peerListenerEndpoint handoff\n", stderr)
            reply(endpoint)
        } catch {
            fputs("[MCPService] peerListenerEndpoint auth failed: \(error.localizedDescription)\n", stderr)
            // Still need a reply of correct type; hand empty anonymous endpoint would be wrong.
            // Fail closed: return our real endpoint only after auth — on failure create a dead anonymous listener once? 
            // Prefer not to leak endpoint. Reply with a fresh anonymous endpoint that has no delegate (useless).
            let dead = NSXPCListener.anonymous()
            reply(dead.endpoint)
        }
    }

    func setDockerHelperPeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        authJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    ) {
        nonisolated(unsafe) let endpoint = endpoint
        nonisolated(unsafe) let authData = authJSON as Data
        let skipMeshVerify = DerrickProcessRole.isDaemon
        Task {
            do {
                _ = try MCPServiceXPCCodec.decodeSignedPeerHandoffAuth(
                    authData,
                    expectedTo: .mcp,
                    expectedKind: .installDockerHelperPeer
                )
                MCPServiceDockerHelperRunner.shared.installPeerEndpoint(endpoint)
                if !skipMeshVerify {
                    try await MCPServiceDockerHelperRunner.shared.verifyPeerMesh()
                }
                await MCPServiceStore.shared.log(
                    level: .info,
                    message: skipMeshVerify
                        ? "Docker helper peer installed (daemon; verify deferred)"
                        : "Docker helper peer mesh verified (MCP→helper)",
                    code: "docker_helper_peer_ok"
                )
                fputs("[MCPService] Docker helper peer endpoint installed\n", stderr)
                let ack = try MCPServiceXPCCodec.encodeSignedAck(.ok, from: .mcp, to: .ui)
                reply(ack as NSData)
            } catch {
                let message = error.localizedDescription
                await MCPServiceStore.shared.log(
                    level: .error,
                    message: "Docker helper peer mesh failed: \(message)",
                    code: "docker_helper_peer_failed"
                )
                fputs("[MCPService] Docker helper peer mesh failed: \(message)\n", stderr)
                let ackData =
                    (try? MCPServiceXPCCodec.encodeSignedAck(.error(message), from: .mcp, to: .ui))
                    ?? (try? DerrickDaemonXPCCodec.encodeAck(.error(message)))
                    ?? Data(#"{"ok":false,"message":"handoff failed"}"#.utf8)
                reply(ackData as NSData)
            }
        }
    }

    func callTool(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try MCPServiceXPCCodec.decodeSignedToolCallRequest(data)
                let result = try await MCPServiceToolHost.shared.callTool(request: request)
                reply((try MCPServiceXPCCodec.encodeToolCallResult(result)) as NSData)
            } catch {
                fputs("[MCPService] callTool failed: \(error.localizedDescription)\n", stderr)
                let result = MCPToolCallResultDTO(
                    requestID: "",
                    ok: false,
                    isError: true,
                    text: "",
                    message: error.localizedDescription
                )
                reply((try? MCPServiceXPCCodec.encodeToolCallResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    func searchTools(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try MCPServiceXPCCodec.decodeSignedToolSearchRequest(data)
                let tools = try await MCPServiceToolHost.shared.searchTools(
                    query: request.query,
                    principal: request.principal
                )
                let result = MCPToolSearchResultDTO(ok: true, tools: tools, message: "ok")
                reply((try MCPServiceXPCCodec.encodeToolSearchResult(result)) as NSData)
            } catch {
                fputs("[MCPService] searchTools failed: \(error.localizedDescription)\n", stderr)
                let result = MCPToolSearchResultDTO(ok: false, tools: [], message: error.localizedDescription)
                reply((try? MCPServiceXPCCodec.encodeToolSearchResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }
}
