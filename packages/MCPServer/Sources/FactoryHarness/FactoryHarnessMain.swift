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
        guard let goalText = ProcessInfo.processInfo.environment["FACTORY_USER_GOAL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !goalText.isEmpty else {
            throw HarnessError.missingUserGoal
        }

        let pluginID = ProcessInfo.processInfo.environment["FACTORY_PLUGIN_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let crawl = ProcessInfo.processInfo.environment["FACTORY_CRAWL_SUMMARY"]
        let input = PluginFactoryCreateInput.makeConnector(
            vendor: .custom,
            pluginID: pluginID,
            auth: try ConnectorAuthDiscovery.botTokenFallback(crawlSummary: crawl),
            customVendorName: "messaging",
            scope: .fullSync,
            userDescription: goalText
        )
        let goal = input.connectorBuildGoal(crawlSummary: crawl)

        fputs("FactoryHarness: building connector…\n", stderr)
        let executor = GoPluginFactoryDockerExecutor(executor: DirectShellDocker.executor())
        let release = try await PluginFactorySession(
            configuration: PluginFactoryConfiguration(maxBuilderAttempts: 3)
        ).build(
            userGoal: goal,
            hostManifest: input.hostManifest,
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
