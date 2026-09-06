import Foundation
import DerrickBackend
import Structure
import DBRepository

/// Boots MCP / Agent / Jobs modules inside derrickd (in-process, no peer mesh).
enum DaemonModuleBootstrap {
    static func startAllModules() async {
        // Mark in-process mesh ready before scheduler claims work.
        JobServiceMeshState.shared.markInProcessReady()

        do {
            _ = try await MCPServiceStore.shared.sharedRepository()
            let daemonRepo = try await DaemonRuntime.shared.sharedRepository()
            await ServiceLogRecorder.shared.configure(repository: daemonRepo)
            _ = try await MCPServiceToolHost.shared.ensureReady()
            InProcessServiceBridges.mcpEnsureReady = {
                _ = try await MCPServiceToolHost.shared.ensureReady()
            }
            InProcessServiceBridges.mcpCallTool = { request in
                do {
                    return try await MCPServiceToolHost.shared.callTool(request: request)
                } catch {
                    return MCPToolCallResultDTO(
                        requestID: request.requestID,
                        ok: false,
                        isError: true,
                        text: "",
                        message: error.localizedDescription
                    )
                }
            }
            InProcessServiceBridges.mcpSearchTools = { principal, query in
                let tools = try await MCPServiceToolHost.shared.searchTools(query: query, principal: principal)
                return MCPToolSearchResultDTO(ok: true, tools: tools, message: "ok")
            }
            InProcessServiceBridges.jobLocalProxy = JobServiceExportedObject()
            InProcessServiceBridges.jobNetworkPreflight = { toolName, argumentsJSON, jobID in
                let repo = try await JobServiceStore.shared.sharedRepository()
                try await JobNetworkPreflight.approveScriptNetworkIfNeeded(
                    toolName: toolName,
                    argumentsJSON: argumentsJSON,
                    jobID: jobID,
                    repository: repo
                )
            }
            InProcessServiceBridges.workflowStart = { request in
                try await WorkflowRuntimeEngine.shared.startWorkflow(request) {
                    try await DaemonRuntime.shared.sharedRepository()
                }
            }
            InProcessServiceBridges.workflowPoll = { request in
                try await WorkflowRuntimeEngine.shared.pollWorkflowUpdate(request) {
                    try await DaemonRuntime.shared.sharedRepository()
                }
            }
            InProcessServiceBridges.workflowCancel = { request in
                try await WorkflowRuntimeEngine.shared.cancelWorkflow(request) {
                    try await DaemonRuntime.shared.sharedRepository()
                }
            }
            InProcessServiceBridges.connectorSubmit = { request in
                try await ConnectorMessagingCommandService.shared.submit(request) {
                    try await DaemonRuntime.shared.sharedRepository()
                }
            }
            InProcessServiceBridges.connectorPoll = { request in
                try await ConnectorMessagingCommandService.shared.poll(request)
            }
            await DaemonRuntime.shared.markModuleReady(.mcp)
            fputs("[derrickd] module mcp ready\n", stderr)
            await sweepEmbeddedDockerLeftovers()
            Task {
                await prewarmGuestRuntimeImage()
            }
            Task {
                await startWebCrawlerImageInBackground()
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

    /// Remove leftover runtime containers before the job scheduler starts.
    /// Guest image pull stays in the background so a cold Python pull does not block jobs.
    private static func sweepEmbeddedDockerLeftovers() async {
        guard DerrickProcessRole.isDaemon else { return }
        do {
            try await MCPServiceDockerHelperRunner.shared.verifyPeerMesh()
            let swept = await MCPServiceDockerHelperRunner.shared.sweepOrphanRuntimeContainers()
            if swept > 0 {
                fputs("[derrickd] removed \(swept) leftover Docker container(s)\n", stderr)
            }
        } catch {
            fputs("[derrickd] embedded Docker leftover sweep skipped: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Embedded DockerRunnerHelper in JobKeepAlive — guest image pull does not block jobs.
    private static func prewarmGuestRuntimeImage() async {
        guard DerrickProcessRole.isDaemon else { return }
        do {
            try await MCPServiceDockerHelperRunner.shared.prewarmGuestRuntime()
            fputs("[derrickd] guest runtime image ready\n", stderr)
        } catch {
            fputs("[derrickd] embedded Docker helper sync failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Does not block jobs or chat. A crawl that arrives during this build waits on the same task.
    private static func startWebCrawlerImageInBackground() async {
        guard DerrickProcessRole.isDaemon else { return }
        do {
            try await MCPServiceDockerHelperRunner.shared.ensureWebCrawlerImage()
            fputs("[derrickd] web crawler image ready\n", stderr)
        } catch {
            fputs("[derrickd] web crawler image background build skipped: \(error.localizedDescription)\n", stderr)
        }
    }
}
