import DBRepository
import DerrickBackend
import FactoryHarnessSupport
import Foundation
import MCPServer
import Plugin
import Structure

enum LiveHarnessError: Error, CustomStringConvertible {
    case missingAPIKey
    case missingSlackToken
    case missingSlackChannel
    case factoryFailed(String)
    case messagingFailed(String)

    var description: String {
        switch self {
        case .missingAPIKey: return "OPENAI_API_KEY is not set."
        case .missingSlackToken: return "Slack bot token is not in Keychain or SLACK_BOT_KEY."
        case .missingSlackChannel: return "Could not resolve a Slack channel for testing."
        case .factoryFailed(let detail): return detail
        case .messagingFailed(let detail): return detail
        }
    }
}

struct LiveHarnessEnvironment {
    static let pluginID = "slack-connection"
    static let displayName = "Slack Connection"

    let repository: DBRepository
    let dockerExecutor: DockerCLIExecutor
    let apiKey: String

    static func bootstrap() async throws -> LiveHarnessEnvironment {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !apiKey.isEmpty else {
            throw LiveHarnessError.missingAPIKey
        }

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
        fputs("[live] app DB: \(await repository.databaseURL.path)\n", stderr)

        await HostHTTPClient.shared.setAccessGate(AllowAllHostHTTPAccessGate())
        await HostHTTPClient.shared.setSecretAttacher(HarnessSecretAttacher(pluginID: pluginID))

        return LiveHarnessEnvironment(
            repository: repository,
            dockerExecutor: DirectShellDocker.executor(),
            apiKey: apiKey
        )
    }

    func cleanupPlugin() async throws {
        try await repository.deletePluginFactoryRelease(pluginID: Self.pluginID)
        let otherConnectorIDs = Set(
            try await repository.listMessagingConnectors()
                .map(\.pluginID)
                .filter { $0 != Self.pluginID }
        )
        try await repository.pruneMessagingConnectors(keeping: otherConnectorIDs)
        try await repository.purgeMessagingMessages(withBodyPrefix: "derrick-e2e")
        try await repository.purgeMessagingMessages(withBodyPrefix: "Derrick live verify")
        fputs("[live] removed prior slack-connection release and connector rows\n", stderr)
    }

    func buildFullSyncConnector() async throws -> PluginFactoryRelease {
        let crawlSummary = """
        Slack Web API chat.postMessage accepts JSON with channel and text. Authenticate with a bot token \
        in Authorization: Bearer. Responses include ok (boolean), channel, ts, and message on success.
        conversations.history returns messages with ts, user, text, and channel.
        conversations.list returns channels with id, name, and is_member.
        conversations.replies returns thread replies when parent_vendor_message_id is set.
        """
        let goal = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: "Send and receive messages in Slack channels I pick from a list."
        ).connectorBuildGoal(crawlSummary: crawlSummary)

        fputs("[live] building full-sync connector via LLM factory…\n", stderr)
        let executor = PythonPluginFactoryDockerExecutor(executor: dockerExecutor)
        let release = try await PluginFactorySession(
            configuration: PluginFactoryConfiguration(maxBuilderAttempts: 3)
        ).build(
            userGoal: goal,
            builder: LiveFactoryBuilder(apiKey: apiKey),
            executor: executor,
            reviewer: ScopeAwareFactoryReviewer(inner: LiveFactoryReviewer(apiKey: apiKey)),
            logger: { message in
                fputs("\(message)\n", stderr)
            }
        )
        try await repository.savePluginFactoryRelease(release)
        fputs(
            "[live] saved \(release.pluginID)@\(release.version) — \(release.reviewSummary)\n",
            stderr
        )
        return release
    }

    func ensureSlackCredentials() throws {
        guard PluginSecretResolver.resolve(pluginID: Self.pluginID, fieldID: "bot_token") != nil else {
            throw LiveHarnessError.missingSlackToken
        }
    }

    func resolveSlackChannelID() async throws -> String {
        if let configured = ProcessInfo.processInfo.environment["SLACK_TEST_CHANNEL_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }
        guard let token = PluginSecretResolver.resolve(pluginID: Self.pluginID, fieldID: "bot_token") else {
            throw LiveHarnessError.missingSlackToken
        }
        var request = URLRequest(
            url: URL(string: "https://slack.com/api/conversations.list?types=public_channel,private_channel&limit=200&exclude_archived=true")!
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LiveHarnessError.missingSlackChannel
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let channels = json["channels"] as? [[String: Any]] else {
            throw LiveHarnessError.missingSlackChannel
        }
        if let member = channels.first(where: { ($0["is_member"] as? Bool) == true }),
           let id = member["id"] as? String {
            return id
        }
        if let general = channels.first(where: { ($0["name"] as? String) == "general" }),
           let id = general["id"] as? String {
            return id
        }
        if let first = channels.first, let id = first["id"] as? String {
            return id
        }
        throw LiveHarnessError.missingSlackChannel
    }

    func makeInvoker() -> ConnectorPluginInvoker {
        ConnectorPluginInvoker { pluginID, input in
            let summaries = try await repository.listPluginFactoryReleaseSummaries()
            guard let summary = summaries.first(where: { $0.pluginID == pluginID }) else {
                throw LiveHarnessError.messagingFailed("No saved release for \(pluginID).")
            }
            guard let release = try await repository.pluginFactoryRelease(
                pluginID: summary.pluginID,
                version: summary.version
            ) else {
                throw LiveHarnessError.messagingFailed("Release missing for \(pluginID).")
            }
            let result = try await GuestPluginRunner.run(
                release: release,
                input: input,
                dockerExecutor: dockerExecutor,
                timeoutSeconds: 180
            )
            guard result.exitCode == 0 else {
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                let stdout = String(decoding: result.stdout, as: UTF8.self)
                throw LiveHarnessError.messagingFailed(stderr.isEmpty ? stdout : stderr)
            }
            let stdout = String(decoding: result.stdout, as: UTF8.self)
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: stdout)
            )
            return try outcome.encodedJSON()
        }
    }

    func registerConnector() async throws {
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(
                pluginID: Self.pluginID,
                displayName: Self.displayName,
                listening: true,
                listeningSince: Date()
            )
        )
        try await repository.setMessagingConnectorListening(pluginID: Self.pluginID, listening: true)
    }
}
