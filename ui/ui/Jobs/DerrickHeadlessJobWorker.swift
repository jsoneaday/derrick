import AppKit
import DBRepository
import Foundation
import ServiceContracts

/// Headless UI process: bootstrap Docker + Agent/MCP/Job mesh, let JobService drain due work, quit.
enum DerrickHeadlessJobWorker {
    private static let idlePollNanoseconds: UInt64 = 2_000_000_000
    private static let idleStableSeconds: TimeInterval = 6
    private static let maxRuntimeSeconds: TimeInterval = 15 * 60

    @MainActor
    static func runUntilIdleThenTerminate() async {
        NSApp.setActivationPolicy(.accessory)
        fputs("[job-worker] starting headless bootstrap\n", stderr)
        do {
            let repo = try await openRepository()
            await EgressAllowlistService.shared.configure(repository: repo)
            await ContentSensitivityGrantService.shared.configure(repository: repo)
            await UsageLimitsService.shared.configure(repository: repo)
            HITLLiveApprovalHandlers.wireAgentServiceClient()

            _ = XPCDockerRunner.shared
            await EgressAllowlistService.shared.pushToHelper()
            try await XPCDockerRunner.shared.waitUntilPrewarmed()

            async let agentHealth = AgentServiceClient.shared.ensureUpAndHealth()
            async let mcpHealth = MCPServiceClient.shared.ensureUpAndHealth()
            async let jobHealth = JobServiceClient.shared.ensureUpAndHealth()
            _ = try await agentHealth
            _ = try await mcpHealth
            _ = try await jobHealth

            let mcpPeer = try await MCPServiceClient.shared.fetchPeerListenerEndpoint()
            try await AgentServiceClient.shared.setMCPServicePeerEndpoint(mcpPeer)
            let jobPeer = try await JobServiceClient.shared.fetchPeerListenerEndpoint()
            try await AgentServiceClient.shared.setJobServicePeerEndpoint(jobPeer)
            try await JobServiceClient.shared.setMCPServicePeerEndpoint(mcpPeer)
            let agentPeer = try await AgentServiceClient.shared.fetchPeerListenerEndpoint()
            try await JobServiceClient.shared.setAgentServicePeerEndpoint(agentPeer)
            let dockerPeer = try await XPCDockerRunner.shared.fetchPeerListenerEndpoint()
            try await MCPServiceClient.shared.setDockerHelperPeerEndpoint(dockerPeer)

            await EgressAllowlistService.shared.pushToHelper()
            fputs("[job-worker] mesh ready — waiting for due jobs to drain\n", stderr)

            let started = Date()
            var idleSince: Date?
            while Date().timeIntervalSince(started) < maxRuntimeSeconds {
                let busy = (try? await repo.hasDueOrRunningJobs()) ?? true
                if busy {
                    idleSince = nil
                } else if let idleSince {
                    if Date().timeIntervalSince(idleSince) >= idleStableSeconds {
                        fputs("[job-worker] queue idle — exiting\n", stderr)
                        break
                    }
                } else {
                    idleSince = Date()
                }
                try? await Task.sleep(nanoseconds: idlePollNanoseconds)
            }
        } catch {
            fputs("[job-worker] failed: \(error.localizedDescription)\n", stderr)
        }
        NSApp.terminate(nil)
    }

    private static func openRepository() async throws -> DBRepository {
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("ui", isDirectory: true)
        let directory = (try? AppDatabaseDirectory.resolve(applicationName: "ui")) ?? fallback
        return try await ConversationModel.makeMemoryStore(
            applicationName: "ui",
            databaseDirectoryURL: directory
        )
    }
}
