import DBRepository
import DerrickBackend
import FactoryHarnessSupport
import Foundation
import MCPServer
import Plugin
import Structure

enum E2EError: Error, CustomStringConvertible {
    case missingAPIKey
    case missingSlackToken
    case missingSlackChannel
    case noRelease(String)
    case pluginInvokeFailed(String)
    case messagingTestFailed(String)
    case factoryFailed(String)

    var description: String {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY is not set."
        case .missingSlackToken:
            return "Slack bot token is not in Keychain or SLACK_BOT_KEY."
        case .missingSlackChannel:
            return "Could not resolve a Slack channel for testing."
        case .noRelease(let pluginID):
            return "No saved release for \(pluginID)."
        case .pluginInvokeFailed(let detail):
            return "plugin.invoke failed: \(detail)"
        case .messagingTestFailed(let detail):
            return "Messaging test failed: \(detail)"
        case .factoryFailed(let detail):
            return "Plugin factory failed: \(detail)"
        }
    }
}

struct E2EEnvironment {
    static let pluginID = "slack-connection"
    static let displayName = "Slack Connection"

    let repository: DBRepository
    let dockerExecutor: DockerCLIExecutor
    let apiKey: String

    static func bootstrap() async throws -> E2EEnvironment {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !apiKey.isEmpty else {
            throw E2EError.missingAPIKey
        }

        let directory = try Self.isolatedDatabaseDirectory()
        try Self.assertIsolatedFromAppDatabase(directory)
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
        fputs("[E2E] isolated DB: \(await repository.databaseURL.path)\n", stderr)
        fputs("[E2E] (does not use the Derrick app database)\n", stderr)

        await HostHTTPClient.shared.setAccessGate(AllowAllHostHTTPAccessGate())
        await HostHTTPClient.shared.setSecretAttacher(HarnessSecretAttacher(pluginID: pluginID))

        return E2EEnvironment(
            repository: repository,
            dockerExecutor: DirectShellDocker.executor(),
            apiKey: apiKey
        )
    }

    /// E2E must never read or write the user's Derrick app database.
    private static func isolatedDatabaseDirectory() throws -> URL {
        if let configured = ProcessInfo.processInfo.environment["E2E_DATABASE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let url = URL(fileURLWithPath: configured, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("derrick-slack-e2e", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func assertIsolatedFromAppDatabase(_ directory: URL) throws {
        let normalized = directory.standardizedFileURL.path
        if normalized.contains("Group Containers/\(DerrickAppSupport.applicationGroupIdentifier)") {
            throw E2EError.messagingTestFailed(
                "Refusing to run E2E against the Derrick app database. Set E2E_DATABASE_DIR to a temp directory."
            )
        }
        if normalized.hasSuffix("/Application Support/ui")
            || normalized.contains("/Containers/derrick.ui/Data/Library/Application Support/ui") {
            throw E2EError.messagingTestFailed(
                "Refusing to run E2E against the Derrick app database. Set E2E_DATABASE_DIR to a temp directory."
            )
        }
    }

    func teardownIsolatedDatabase() async throws {
        let directory = await repository.databaseDirectoryURL
        try Self.assertIsolatedFromAppDatabase(directory)
        try FileManager.default.removeItem(at: directory)
    }

    func makeInvoker() -> ConnectorPluginInvoker {
        ConnectorPluginInvoker { pluginID, input in
            let summaries = try await repository.listPluginFactoryReleaseSummaries()
            guard let summary = summaries.first(where: { $0.pluginID == pluginID }) else {
                throw E2EError.noRelease(pluginID)
            }
            guard let release = try await repository.pluginFactoryRelease(
                pluginID: summary.pluginID,
                version: summary.version
            ) else {
                throw E2EError.noRelease(pluginID)
            }

            let secrets = PluginSecretField.fields(fromManifestJSON: Data(release.manifestJSON.utf8))
            let missing = secrets.map(\.descriptor).filter {
                PluginSecretResolver.resolve(pluginID: release.pluginID, fieldID: $0.id) == nil
            }
            if !missing.isEmpty {
                throw E2EError.messagingTestFailed(
                    "Missing secrets: \(missing.map(\.id).joined(separator: ", "))"
                )
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
                throw E2EError.pluginInvokeFailed(
                    stderr.isEmpty ? stdout : stderr
                )
            }
            let stdout = String(decoding: result.stdout, as: UTF8.self)
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: stdout)
            )
            return try outcome.encodedJSON()
        }
    }

    func ensureSlackCredentials() throws {
        guard PluginSecretResolver.resolve(pluginID: Self.pluginID, fieldID: "bot_token") != nil else {
            throw E2EError.missingSlackToken
        }
    }

    func resolveSlackChannelID() async throws -> String {
        if let configured = ProcessInfo.processInfo.environment["SLACK_TEST_CHANNEL_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }

        guard let token = PluginSecretResolver.resolve(pluginID: Self.pluginID, fieldID: "bot_token") else {
            throw E2EError.missingSlackToken
        }

        var request = URLRequest(url: URL(string: "https://slack.com/api/conversations.list?types=public_channel,private_channel&limit=200&exclude_archived=true")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw E2EError.missingSlackChannel
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let channels = json["channels"] as? [[String: Any]] else {
            throw E2EError.missingSlackChannel
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
        throw E2EError.missingSlackChannel
    }

    /// Posts a message to Slack outside the connector adapter (simulates an inbound message).
    func postSlackMessage(channelID: String, text: String) async throws {
        guard let token = PluginSecretResolver.resolve(pluginID: Self.pluginID, fieldID: "bot_token") else {
            throw E2EError.missingSlackToken
        }
        var request = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["channel": channelID, "text": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw E2EError.messagingTestFailed("Slack chat.postMessage HTTP failed.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw E2EError.messagingTestFailed("Slack chat.postMessage failed: \(error ?? "unknown")")
        }
    }

    func cleanupPlugin() async throws {
        try await repository.deletePluginFactoryRelease(pluginID: Self.pluginID)
        let otherConnectorIDs = Set(
            try await repository.listMessagingConnectors()
                .map(\.pluginID)
                .filter { $0 != Self.pluginID }
        )
        try await repository.pruneMessagingConnectors(keeping: otherConnectorIDs)
    }

    func registerConnector(listening: Bool = true) async throws {
        try await Self.ensureConnectorRegistered(repository: repository, listening: listening)
    }

    /// Upsert and verify the connector row exists before messaging writes.
    static func ensureConnectorRegistered(
        repository: DBRepository,
        listening: Bool = true
    ) async throws {
        for attempt in 1...3 {
            try await repository.upsertMessagingConnector(
                MessagingConnectorDTO(
                    pluginID: pluginID,
                    displayName: displayName,
                    listening: listening
                )
            )
            let registered = try await repository.listMessagingConnectors()
                .contains { $0.pluginID == pluginID }
            if registered { return }
            if attempt < 3 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw E2EError.messagingTestFailed(
            "Messaging connector '\(pluginID)' is not registered."
        )
    }

    func ensureConnectorRegistered(listening: Bool = true) async throws {
        try await Self.ensureConnectorRegistered(repository: repository, listening: listening)
    }

    func buildConnector(scope: PluginFactoryCreateInput.ConnectorScope) async throws -> PluginFactoryRelease {
        let input = try SlackConnectorFactoryInput.make(
            pluginID: Self.pluginID,
            userDescription: "Post alerts to Slack channels."
        )
        let goal = input.connectorBuildGoal(crawlSummary: SlackConnectorFactoryInput.defaultCrawlSummary)

        fputs("[E2E] factory build scope=\(scope.rawValue)…\n", stderr)
        let executor = GoPluginFactoryDockerExecutor(executor: dockerExecutor)
        let release = try await PluginFactorySession(
            configuration: PluginFactoryConfiguration(maxBuilderAttempts: 5)
        ).build(
            userGoal: goal,
            hostManifest: input.hostManifest,
            builder: E2EFactoryBuilder(scope: scope),
            executor: executor,
            reviewer: E2EHarnessReviewer(),
            logger: { message in
                fputs("\(message)\n", stderr)
            }
        )
        try await repository.savePluginFactoryRelease(release)
        fputs(
            "[E2E] saved \(release.pluginID)@\(release.version) — \(release.reviewSummary)\n",
            stderr
        )
        return release
    }
}
