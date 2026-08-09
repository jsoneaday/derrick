import Foundation
import DerrickBackend
import ServiceContracts

/// Boots MCP / Agent / Jobs modules inside derrickd (in-process, no peer mesh).
enum DaemonModuleBootstrap {
    static func startAllModules() async {
        // Mark in-process mesh ready before scheduler claims work.
        JobServiceMeshState.shared.markInProcessReady()

        do {
            _ = try await MCPServiceStore.shared.sharedRepository()
            _ = try await MCPServiceToolHost.shared.ensureReady()
            InProcessServiceBridges.mcpEnsureReady = {
                _ = try await MCPServiceToolHost.shared.ensureReady()
            }
            InProcessServiceBridges.mcpCallTool = { request in
                try await MCPServiceToolHost.shared.callTool(request: request)
            }
            InProcessServiceBridges.mcpSearchTools = { principal, query in
                let tools = try await MCPServiceToolHost.shared.searchTools(query: query, principal: principal)
                return MCPToolSearchResultDTO(ok: true, tools: tools, message: "ok")
            }
            InProcessServiceBridges.jobLocalProxy = JobServiceExportedObject()
            await DaemonRuntime.shared.markModuleReady(.mcp)
            fputs("[derrickd] module mcp ready\n", stderr)
            Task {
                await syncEmbeddedDockerHelper()
            }
        } catch {
            fputs("[derrickd] MCP module bootstrap failed: \(error.localizedDescription)\n", stderr)
        }

        do {
            _ = try await AgentServiceStore.shared.sharedRepository()
            await DaemonRuntime.shared.markModuleReady(.agent)
            fputs("[derrickd] module agent ready\n", stderr)
        } catch {
            fputs("[derrickd] Agent module bootstrap failed: \(error.localizedDescription)\n", stderr)
        }

        do {
            _ = try await JobServiceStore.shared.sharedRepository()
            JobServiceScheduler.shared.start()
            await DaemonRuntime.shared.markModuleReady(.jobs)
            fputs("[derrickd] module jobs ready (scheduler started)\n", stderr)
        } catch {
            fputs("[derrickd] Jobs module bootstrap failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Embedded DockerRunnerHelper in JobKeepAlive — sync egress + verify without blocking bootstrap.
    private static func syncEmbeddedDockerHelper() async {
        guard DerrickProcessRole.isDaemon else { return }
        do {
            let repo = try await MCPServiceStore.shared.sharedRepository()
            let rows = try await repo.loadEgressAllowedDomainSuffixes(includeDisabled: false)
            let suffixes = rows.filter(\.enabled).map(\.suffix)
            await MCPServiceDockerHelperRunner.shared.pushEgressAllowedDomainSuffixes(suffixes)
            try await MCPServiceDockerHelperRunner.shared.verifyPeerMesh()
            fputs("[derrickd] embedded Docker helper verified (egress count=\(suffixes.count))\n", stderr)
        } catch {
            fputs("[derrickd] embedded Docker helper sync failed: \(error.localizedDescription)\n", stderr)
        }
    }
}
