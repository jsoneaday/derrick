import Foundation

/// Stable authority name requested by an Actor.
public struct CapabilityID: RawRepresentable, Codable, Sendable, Hashable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public struct CapabilitySet: Codable, Sendable, Hashable {
    public let values: Set<CapabilityID>

    public init(_ values: Set<CapabilityID> = []) {
        self.values = values
    }

    public func contains(_ capability: CapabilityID) -> Bool {
        values.contains(capability)
    }
}

public struct CapabilityRequest: Codable, Sendable, Hashable {
    public let actor: ActorID
    public let capability: CapabilityID
    public let resource: String?
    public let sessionID: String?
    public let workflowID: String?

    public init(
        actor: ActorID,
        capability: CapabilityID,
        resource: String? = nil,
        sessionID: String? = nil,
        workflowID: String? = nil
    ) {
        self.actor = actor
        self.capability = capability
        self.resource = resource
        self.sessionID = sessionID
        self.workflowID = workflowID
    }
}

public enum CapabilityDecision: Codable, Sendable, Hashable {
    case allowed
    case denied(reason: String)
}

/// Capability authority used before a Guardrail decision is evaluated.
public protocol ActorCapabilityChecking: Sendable {
    func check(_ request: CapabilityRequest) async throws -> CapabilityDecision
}
