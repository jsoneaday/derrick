import Foundation

/// Broad identity category used when an Actor requests a capability.
public enum ActorKind: String, Codable, Sendable, Hashable, CaseIterable {
    case humanOperator = "operator"
    case ui
    case agent
    case pluginGuest = "plugin_guest"
    case module
    case service
    case job
    case workflow
    case system
    case webhook
}

/// Stable identity for the Actor attempting a command or SideEffect.
public struct ActorID: Codable, Sendable, Hashable, Identifiable {
    public let kind: ActorKind
    public let value: String

    public var id: String {
        "\(kind.rawValue):\(value)"
    }

    public init(kind: ActorKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// Runtime category for an AgentInstance. This is separate from AgentRole,
/// AgentStatus, and AgentConfiguration.
public enum AgentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case interactive
    case delegated
    case scheduled
    case workflow
    case integration
    case system
}

/// Immutable configuration identity attached to an AgentInstance and its
/// historical turns.
public struct AgentConfigurationReference: Codable, Sendable, Hashable {
    public let configurationID: String
    public let configurationVersion: Int
    public let snapshotHash: String?

    public init(
        configurationID: String,
        configurationVersion: Int,
        snapshotHash: String? = nil
    ) {
        self.configurationID = configurationID
        self.configurationVersion = configurationVersion
        self.snapshotHash = snapshotHash
    }
}
