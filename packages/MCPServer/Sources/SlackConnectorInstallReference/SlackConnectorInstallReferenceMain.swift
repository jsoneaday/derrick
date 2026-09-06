import DBRepository
import DerrickBackend
import FactoryHarnessSupport
import Foundation
import MCPServer
import Plugin
import Structure

@main
enum SlackConnectorInstallReference {
    static func main() async {
        do {
            try await run()
            fputs("SlackConnectorInstallReference: SUCCESS\n", stderr)
        } catch {
            fputs("SlackConnectorInstallReference: FAILED — \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let pluginID = "slack-connection"
        let directory = try DerrickAppSupport.databaseDirectory()
        let repository = DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: DerrickAppSupport.defaultApplicationName,
                databaseName: "derrick",
                databaseDirectoryURL: directory,
                username: "ui",
                password: "ui"
            )
        )
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        fputs("[install] DB: \(await repository.databaseURL.path)\n", stderr)

        try await repository.deletePluginFactoryRelease(pluginID: pluginID)
        try await repository.pruneMessagingConnectors(keeping: [])

        let dockerExecutor = DirectShellDocker.executor()
        let executor = PythonPluginFactoryDockerExecutor(executor: dockerExecutor)
        let goal = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: "Send and receive messages in Slack channels I pick from a list."
        ).connectorBuildGoal(crawlSummary: "Slack conversations.list, conversations.history, conversations.replies, chat.postMessage.")

        fputs("[install] packaging reference full-sync connector…\n", stderr)
        let release = try await PluginFactorySession(
            configuration: PluginFactoryConfiguration(maxBuilderAttempts: 1)
        ).build(
            userGoal: goal,
            builder: E2EFactoryBuilder(scope: .fullSync),
            executor: executor,
            reviewer: E2EHarnessReviewer(),
            logger: { fputs("\($0)\n", stderr) }
        )
        try await repository.savePluginFactoryRelease(release)
        fputs("[install] saved \(release.pluginID)@\(release.version)\n", stderr)

        let fields = PluginSecretField.fields(fromManifestJSON: Data(release.manifestJSON.utf8))
            .map(\.descriptor)
        PluginSecretHostMirror.syncDevelopmentSecretsToKeychain(
            pluginID: pluginID,
            fields: fields
        )
        guard PluginSecretResolver.resolve(pluginID: pluginID, fieldID: "bot_token") != nil else {
            throw InstallError("Slack bot token missing. Set SLACK_BOT_KEY in ui/ui/Resources/.env.")
        }

        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(
                pluginID: pluginID,
                displayName: "Slack Connection",
                listening: true,
                listeningSince: Date()
            )
        )

        await HostHTTPClient.shared.setAccessGate(AllowAllHostHTTPAccessGate())
        await HostHTTPClient.shared.setSecretAttacher(HarnessSecretAttacher(pluginID: pluginID))

        let invoker = ConnectorPluginInvoker { _, input in
            let result = try await GuestPluginRunner.run(
                release: release,
                input: input,
                dockerExecutor: dockerExecutor,
                timeoutSeconds: 180
            )
            guard result.exitCode == 0 else {
                let stderrText = String(decoding: result.stderr, as: UTF8.self)
                let stdoutText = String(decoding: result.stdout, as: UTF8.self)
                throw InstallError(stderrText.isEmpty ? stdoutText : stderrText)
            }
            let stdout = String(decoding: result.stdout, as: UTF8.self)
            return try ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: stdout)
            ).encodedJSON()
        }

        let adapter = PluginMessagingIngressAdapter(pluginID: pluginID, invoker: invoker)
        try await adapter.bootstrap(repository: repository)
        let threads = try await repository.listMessagingThreads(pluginID: pluginID)
        fputs("[install] bootstrap loaded \(threads.count) conversation(s)\n", stderr)
        for thread in threads.prefix(8) {
            fputs("  - \(thread.title) (\(thread.vendorThreadID))\n", stderr)
        }
        guard !threads.isEmpty else {
            throw InstallError("Bootstrap completed but no conversations were loaded.")
        }
    }
}

private struct InstallError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
