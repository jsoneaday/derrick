import Foundation

/// Resolves declared plugin secrets from Keychain and/or dev `.env` files.
public enum PluginSecretResolver: Sendable {
    public static var usesDotenvOnly: Bool { DotEnvReader.usesDotenvOnly }

    public static func resolve(pluginID: String, fieldID: String) -> String? {
        let keys = environmentKeys(pluginID: pluginID, fieldID: fieldID)
        switch DotEnvReader.secretSourceMode() {
        case .dotenv:
            return DotEnvReader.firstValue(for: keys)
                ?? ProcessInfo.processInfo.environment.firstValue(for: keys)
        case .keychain:
            return (try? PluginSecretKeychain.loadFromKeychain(pluginID: pluginID, fieldID: fieldID))
                ?? ProcessInfo.processInfo.environment.firstValue(for: keys)
                ?? DotEnvReader.firstValue(for: keys)
        }
    }

    public static func missingDotenvMessage(pluginID: String, fieldID: String) -> String {
        DotEnvReader.missingSecretMessage(
            variableKeys: environmentKeys(pluginID: pluginID, fieldID: fieldID)
        )
    }

    public static func environmentKeys(pluginID: String, fieldID: String) -> [String] {
        var keys = knownAliases(pluginID: pluginID, fieldID: fieldID)
        let pluginToken = pluginID.uppercased().replacingOccurrences(of: "-", with: "_")
        let fieldToken = fieldID.uppercased()
        keys.append("PLUGIN_\(pluginToken)_\(fieldToken)")
        return keys
    }

    private static func knownAliases(pluginID: String, fieldID: String) -> [String] {
        if pluginID == "slack-connection", fieldID == "bot_token" {
            return ["SLACK_BOT_KEY", "SLACK_API_KEY"]
        }
        return []
    }
}

private extension Dictionary where Key == String, Value == String {
    func firstValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
