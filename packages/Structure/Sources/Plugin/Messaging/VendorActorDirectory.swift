import Foundation

/// Resolves an opaque vendor actor id (user id) to a human display name.
public protocol VendorActorDisplayNameResolving: Sendable {
    func displayName(pluginID: String, actorID: String) async -> String?
}

/// Resolves the connector's own vendor actor id (bot user) so the host can ignore echoes.
public protocol VendorSelfActorResolving: Sendable {
    func selfActorID(pluginID: String) async -> String?
}

/// Process-wide vendor adapters. Slack (and later vendors) register outside Structure.
public actor VendorActorDirectory {
    public static let shared = VendorActorDirectory()

    private var displayNames: (any VendorActorDisplayNameResolving)?
    private var selfActor: (any VendorSelfActorResolving)?

    public func setDisplayNameResolver(_ resolver: (any VendorActorDisplayNameResolving)?) {
        displayNames = resolver
    }

    public func setSelfActorResolver(_ resolver: (any VendorSelfActorResolving)?) {
        selfActor = resolver
    }

    public func displayName(pluginID: String, actorID: String) async -> String? {
        await displayNames?.displayName(pluginID: pluginID, actorID: actorID)
    }

    public func selfActorID(pluginID: String) async -> String? {
        await selfActor?.selfActorID(pluginID: pluginID)
    }
}

public enum MessagingSenderDisplayName: Sendable {
    public static func resolve(pluginID: String, sender: String) async -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sender }
        guard MessagingInboundNotificationCopy.isOpaqueVendorActorID(trimmed),
              let resolved = await VendorActorDirectory.shared.displayName(
                pluginID: pluginID,
                actorID: trimmed
              )
        else {
            return sender
        }
        return resolved
    }
}
