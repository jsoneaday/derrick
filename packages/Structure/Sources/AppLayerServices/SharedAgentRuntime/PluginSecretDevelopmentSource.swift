import Foundation

/// Development escape hatch for plugin connector credentials.
///
/// When enabled (`UI_SECRET_MODE=dotenv`, `IS_DEBUG=true`, or `#if DEBUG` builds),
/// plugin secrets are read from environment / `.env` instead of Keychain so local
/// development does not trigger repeated Keychain access prompts.
public enum PluginSecretDevelopmentSource: Sendable {
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> Bool {
        DotEnvReader.secretSourceMode(
            environment: environment,
            bundleURL: bundleURL,
            currentDirectoryURL: currentDirectoryURL
        ) == .dotenv || MessagesSecretKey.isDebugMode(
            environment: environment,
            bundleURL: bundleURL,
            currentDirectoryURL: currentDirectoryURL
        )
    }

    public static func environmentVariableKey(pluginID: String, fieldID: String) -> String {
        let plugin = pluginID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        let field = fieldID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        return "PLUGIN_\(plugin)_\(field)"
    }

    public static func resolve(
        pluginID: String,
        fieldID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> String? {
        guard isEnabled(
            environment: environment,
            bundleURL: bundleURL,
            currentDirectoryURL: currentDirectoryURL
        ) else {
            return nil
        }
        for key in candidateEnvironmentKeys(pluginID: pluginID, fieldID: fieldID) {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
            if let value = DotEnvReader.value(
                for: key,
                environment: environment,
                bundleURL: bundleURL,
                currentDirectoryURL: currentDirectoryURL
            ) {
                return value
            }
        }
        return nil
    }

    private static func candidateEnvironmentKeys(pluginID: String, fieldID: String) -> [String] {
        var keys = [environmentVariableKey(pluginID: pluginID, fieldID: fieldID)]
        let trimmedPluginID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFieldID = fieldID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPluginID == "slack-connection", trimmedFieldID == "bot_token" {
            keys.append(contentsOf: ["SLACK_BOT_KEY", "SLACK_BOT_TOKEN"])
        }
        return keys
    }
}
