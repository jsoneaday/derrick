import DerrickBackend
import Foundation
import Structure

@main
enum SlackConnectorE2EHarnessMain {
    static func main() async {
        do {
            try await runAllScopes()
            fputs("SlackConnectorE2E: ALL SCOPES PASSED\n", stderr)
        } catch {
            fputs("SlackConnectorE2E: FAILED — \(error)\n", stderr)
            exit(1)
        }
    }

    private static func runAllScopes() async throws {
        let env = try await E2EEnvironment.bootstrap()
        try env.ensureSlackCredentials()
        let channelID = try await env.resolveSlackChannelID()
        fputs("[E2E] using Slack channel \(channelID)\n", stderr)

        for scope in scopesToRun() {
            fputs("\n[E2E] === scope: \(scope.displayName) ===\n", stderr)
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
            fputs("[E2E] deleted plugin after \(scope.displayName) pass\n", stderr)
        }
        try await env.teardownIsolatedDatabase()
        fputs("[E2E] removed isolated test database\n", stderr)
    }

    private static func scopesToRun() -> [PluginFactoryCreateInput.ConnectorScope] {
        if let raw = ProcessInfo.processInfo.environment["E2E_SCOPE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let scope = PluginFactoryCreateInput.ConnectorScope(rawValue: raw) {
            return [scope]
        }
        return PluginFactoryCreateInput.ConnectorScope.allCases
    }
}
