import FactoryHarnessSupport
import Foundation
import MCPServer
import Plugin
import Structure

@main
enum FactoryHarnessMain {
    static func main() async {
        do {
            try await run()
            fputs("FactoryHarness: success\n", stderr)
        } catch {
            fputs("FactoryHarness: failed — \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !apiKey.isEmpty else {
            throw HarnessError.missingAPIKey
        }

        let goal = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .sendOnly,
            userDescription: "Post alerts to Slack channels."
        ).connectorBuildGoal(
            crawlSummary: """
            Slack Web API chat.postMessage accepts JSON with channel and text. Authenticate with a bot token \
            in Authorization: Bearer. Responses include ok (boolean), channel, ts, and message on success.
            """
        )

        fputs("FactoryHarness: building slack send-only connector…\n", stderr)
        let executor = PythonPluginFactoryDockerExecutor(executor: DirectShellDocker.executor())
        let release = try await PluginFactorySession(
            configuration: PluginFactoryConfiguration(maxBuilderAttempts: 3)
        ).build(
            userGoal: goal,
            builder: LiveFactoryBuilder(apiKey: apiKey),
            executor: executor,
            reviewer: LiveFactoryReviewer(apiKey: apiKey),
            logger: { message in
                fputs("\(message)\n", stderr)
            }
        )

        let summary = """
        {"ok":true,"plugin_id":"\(release.pluginID)","version":"\(release.version)",\
        "content_hash":"\(release.contentHash.rawValue)","review_summary":"\(release.reviewSummary)"}
        """
        print(summary)
    }
}
