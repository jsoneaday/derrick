import DBRepository
import DerrickBackend
import FactoryHarnessSupport
import Foundation
import MCPServer
import Plugin
import Structure

@main
enum SlackConnectorBootstrapProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("BootstrapProbe FAILED: \(error)\n", stderr)
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
        fputs("[probe] DB: \(await repository.databaseURL.path)\n", stderr)

        await HostHTTPClient.shared.setAccessGate(AllowAllHostHTTPAccessGate())
        await HostHTTPClient.shared.setSecretAttacher(HarnessSecretAttacher(pluginID: pluginID))

        let summaries = try await repository.listPluginFactoryReleaseSummaries()
        guard let summary = summaries.first(where: { $0.pluginID == pluginID }) else {
            throw ProbeError("No release for \(pluginID)")
        }
        guard let release = try await repository.pluginFactoryRelease(
            pluginID: summary.pluginID,
            version: summary.version
        ) else {
            throw ProbeError("Release row missing")
        }

        let secrets = PluginSecretField.fields(fromManifestJSON: Data(release.manifestJSON.utf8))
        let fields = secrets.map(\.descriptor)
        let missing = PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: fields)
        fputs("[probe] missing secrets: \(missing.map(\.id))\n", stderr)
        PluginSecretHostMirror.syncDevelopmentSecretsToKeychain(pluginID: pluginID, fields: fields)

        let invoker = ConnectorPluginInvoker { _, input in
            let result = try await GuestPluginRunner.run(
                release: release,
                input: input,
                dockerExecutor: DirectShellDocker.executor(),
                timeoutSeconds: 180
            )
            guard result.exitCode == 0 else {
                let stderrText = String(decoding: result.stderr, as: UTF8.self)
                let stdoutText = String(decoding: result.stdout, as: UTF8.self)
                throw ProbeError(stderrText.isEmpty ? stdoutText : stderrText)
            }
            let stdout = String(decoding: result.stdout, as: UTF8.self)
            return try ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: stdout)
            ).encodedJSON()
        }

        let adapter = PluginMessagingIngressAdapter(pluginID: pluginID, invoker: invoker)
        guard adapter.hasCredentials() else {
            throw ProbeError("hasCredentials=false")
        }
        try await adapter.syncThreads(repository: repository)
        let threads = try await repository.listMessagingThreads(pluginID: pluginID)
        fputs("[probe] threads=\(threads.count)\n", stderr)
        for thread in threads.prefix(10) {
            fputs("  - \(thread.title) (\(thread.vendorThreadID))\n", stderr)
        }
        if threads.isEmpty {
            throw ProbeError("sync_threads completed but returned 0 threads")
        }
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
