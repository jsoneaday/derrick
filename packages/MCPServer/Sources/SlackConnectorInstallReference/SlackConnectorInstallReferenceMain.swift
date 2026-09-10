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

        try await deleteExistingConnectors(repository: repository)

        let dockerExecutor = DirectShellDocker.executor()
        let first = try await createWorkingSlackConnector(
            pluginID: "slack-connector-1",
            repository: repository,
            dockerExecutor: dockerExecutor
        )
        let second = try await createWorkingSlackConnector(
            pluginID: "slack-connector-2",
            repository: repository,
            dockerExecutor: dockerExecutor
        )
        guard first != second else {
            throw InstallError("Second create reused plugin id \(first).")
        }
        fputs("[install] created \(first) then \(second)\n", stderr)
    }

    private static func deleteExistingConnectors(repository: DBRepository) async throws {
        let summaries = try await repository.listPluginFactoryReleaseSummaries()
        var seen = Set<String>()
        for summary in summaries {
            let pluginID = summary.pluginID
            guard seen.insert(pluginID).inserted else { continue }
            let slack = pluginID.localizedCaseInsensitiveContains("slack")
            if slack {
                try await repository.deletePluginFactoryRelease(pluginID: pluginID)
                fputs("[install] deleted factory release \(pluginID)\n", stderr)
            }
        }
        try await repository.pruneMessagingConnectors(keeping: [])
        fputs("[install] cleared messaging connectors\n", stderr)
    }

    private static func createWorkingSlackConnector(
        pluginID: String,
        repository: DBRepository,
        dockerExecutor: @escaping DockerCLIExecutor
    ) async throws -> String {
        let input = try SlackConnectorFactoryInput.make(pluginID: pluginID)
        let goal = input.connectorBuildGoal(
            crawlSummary: SlackConnectorFactoryInput.defaultCrawlSummary
        )
        fputs("[install] packaging \(pluginID)…\n", stderr)
        let release = try await PluginFactorySession(
            configuration: PluginFactoryConfiguration(maxBuilderAttempts: 1)
        ).build(
            userGoal: goal,
            hostManifest: input.hostManifest,
            builder: E2EFactoryBuilder(scope: .fullSync),
            executor: GoPluginFactoryDockerExecutor(executor: dockerExecutor),
            reviewer: E2EHarnessReviewer(),
            logger: { fputs("\($0)\n", stderr) }
        )
        guard release.pluginID == pluginID else {
            throw InstallError("Factory saved \(release.pluginID) instead of \(pluginID).")
        }
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
                displayName: pluginID,
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
        fputs("[install] \(pluginID) bootstrap loaded \(threads.count) conversation(s)\n", stderr)
        for thread in threads.prefix(8) {
            fputs("  - \(thread.title) (\(thread.vendorThreadID))\n", stderr)
        }
        guard !threads.isEmpty else {
            throw InstallError("Bootstrap of \(pluginID) completed but no conversations were loaded.")
        }
        return pluginID
    }
}

private struct InstallError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
