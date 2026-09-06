import DerrickBackend
import Foundation
import Structure

@main
enum SlackConnectorE2EHarnessMain {
    static func main() async {
        do {
            try await run()
            fputs("SlackConnectorE2E: PASSED\n", stderr)
        } catch {
            fputs("SlackConnectorE2E: FAILED — \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let env = try await E2EEnvironment.bootstrap()
        try env.ensureSlackCredentials()
        let channelID = try await env.resolveSlackChannelID()
        fputs("[E2E] using Slack channel \(channelID)\n", stderr)

        let scope = PluginFactoryCreateInput.ConnectorScope.fullSync
        fputs("\n[E2E] === full sync ===\n", stderr)
        try await env.cleanupPlugin()
        _ = try await env.buildConnector(scope: scope)
        try await env.registerConnector()
        let adapter = PluginMessagingIngressAdapter(
            pluginID: E2EEnvironment.pluginID,
            invoker: env.makeInvoker()
        )
        try await E2EMessagingTests.run(
            scope: scope,
            adapter: adapter,
            repository: env.repository,
            channelID: channelID,
            environment: env
        )
        try await env.cleanupPlugin()
        fputs("[E2E] deleted plugin after full sync pass\n", stderr)
        try await env.teardownIsolatedDatabase()
        fputs("[E2E] removed isolated test database\n", stderr)
    }
}
