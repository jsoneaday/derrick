import Foundation

/// Guest `result.emit` should already include a human sender. The host does not call vendors.
public enum MessagingSenderDisplayName: Sendable {
    public static func resolve(pluginID: String, sender: String) async -> String {
        _ = pluginID
        return sender
    }
}
