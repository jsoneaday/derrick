import Foundation

/// Identifies and removes legacy Slack reference connector installs from the factory store.
public enum PluginFactoryLegacyPurge: Sendable {
    public static func isLegacySlackPluginID(_ pluginID: String) -> Bool {
        pluginID.lowercased().contains("slack")
    }
}
