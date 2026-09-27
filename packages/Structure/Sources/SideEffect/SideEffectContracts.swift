import Foundation

public struct NetworkSideEffectRequest: Codable, Sendable, Hashable {
    public let actor: ActorID
    public let correlationID: String
    public let request: HostHTTPRequest

    public init(
        actor: ActorID,
        correlationID: String,
        request: HostHTTPRequest
    ) {
        self.actor = actor
        self.correlationID = correlationID
        self.request = request
    }
}

public struct NetworkSideEffectResult: Codable, Sendable, Hashable {
    public let response: HostHTTPResponse

    public init(response: HostHTTPResponse) {
        self.response = response
    }
}

public protocol NetworkSideEffectExecuting: Sendable {
    func execute(_ request: NetworkSideEffectRequest) async throws -> NetworkSideEffectResult
}

public struct UISideEffectRequest: Codable, Sendable, Hashable {
    public let actor: ActorID
    public let correlationID: String
    public let pluginID: String
    public let root: HostUINode

    public init(
        actor: ActorID,
        correlationID: String,
        pluginID: String,
        root: HostUINode
    ) {
        self.actor = actor
        self.correlationID = correlationID
        self.pluginID = pluginID
        self.root = root
    }
}

public struct UISideEffectResult: Codable, Sendable, Hashable {
    public let accepted: Bool
    public let presentationID: String?

    public init(accepted: Bool, presentationID: String? = nil) {
        self.accepted = accepted
        self.presentationID = presentationID
    }
}

public protocol UISideEffectExecuting: Sendable {
    func execute(_ request: UISideEffectRequest) async throws -> UISideEffectResult
}

public enum HostSideEffectPayload: Codable, Sendable, Hashable {
    case network(NetworkSideEffectRequest)
    case ui(UISideEffectRequest)
}

public struct HostSideEffectRequest: Codable, Sendable, Hashable {
    public let payload: HostSideEffectPayload

    public init(payload: HostSideEffectPayload) {
        self.payload = payload
    }
}

public enum HostSideEffectResultPayload: Codable, Sendable, Hashable {
    case network(NetworkSideEffectResult)
    case ui(UISideEffectResult)
}

public struct HostSideEffectResult: Codable, Sendable, Hashable {
    public let payload: HostSideEffectResultPayload

    public init(payload: HostSideEffectResultPayload) {
        self.payload = payload
    }
}

/// Central host authority that validates and routes approved SideEffects.
public protocol HostSideEffectExecuting: Sendable {
    func execute(_ request: HostSideEffectRequest) async throws -> HostSideEffectResult
}

public enum HostSecretScope: String, Codable, Sendable, Hashable, CaseIterable {
    case pluginHTTP = "plugin_http"
    case modelProvider = "model_provider"
    case serviceAuthentication = "service_authentication"
    case database
}

public struct HostSecretReference: Codable, Sendable, Hashable {
    public let scope: HostSecretScope
    public let ownerID: String
    public let fieldID: String

    public init(scope: HostSecretScope, ownerID: String, fieldID: String) {
        self.scope = scope
        self.ownerID = ownerID
        self.fieldID = fieldID
    }
}

/// Attaches a host-owned secret to a host request without exposing the value
/// to a plugin guest.
public protocol HostSecretAttaching: Sendable {
    func attach(
        _ request: HostHTTPRequest,
        using reference: HostSecretReference
    ) async throws -> HostHTTPRequest
}
