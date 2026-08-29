import Foundation

/// Host-owned Derrick role in `extensions.app.derrick.role`.
/// Do not infer this from the plugin id or display name.
public enum PluginRole: String, Codable, Sendable, Hashable {
    case standard
    case connector

    public var isConnector: Bool { self == .connector }
}
