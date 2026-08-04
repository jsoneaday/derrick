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
        let text = MCPServiceXPCCodec.decodeString(payload as Data)
        Task {
            await MCPServiceStore.shared.log(level: .debug, message: "ping", code: "ping")
            reply(MCPServiceXPCCodec.encodeString("pong:\(text)") as NSData)
        }
    }

    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let repo = try await MCPServiceStore.shared.sharedRepository()
                _ = try await MCPServiceToolHost.shared.ensureReady()
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

    func callTool(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try MCPServiceXPCCodec.decodeToolCallRequest(data)
                let result = try await MCPServiceToolHost.shared.callTool(request: request)
                reply((try MCPServiceXPCCodec.encodeToolCallResult(result)) as NSData)
            } catch {
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
                let request = try MCPServiceXPCCodec.decodeToolSearchRequest(data)
                let tools = try await MCPServiceToolHost.shared.searchTools(
                    query: request.query,
                    principal: request.principal
                )
                let result = MCPToolSearchResultDTO(ok: true, tools: tools, message: "ok")
                reply((try MCPServiceXPCCodec.encodeToolSearchResult(result)) as NSData)
            } catch {
                let result = MCPToolSearchResultDTO(ok: false, tools: [], message: error.localizedDescription)
                reply((try? MCPServiceXPCCodec.encodeToolSearchResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }
}
