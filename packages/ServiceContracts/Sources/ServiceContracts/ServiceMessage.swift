import Foundation

/// Cross-service command/event types (payload is JSON object as Data).
public enum ServiceMessageType: String, Codable, Sendable, Hashable {
    // Health / control (health/bootstrap stay unsigned on the wire)
    case health
    case ping
    case peerHandoff
    // Jobs
    case createJob
    case cancelJob
    case jobDue
    case jobTerminal
    // Agents
    case wakeAgent
    case injectUserMessage
    case cancelTurn
    case approvalRequest
    case approvalDecision
    case networkAccessRequest
    case networkAccessDecision
    // MCP
    case runTool
    case searchTools
    // Webhook ack
    case webhookAccepted
    case webhookRejected
}

/// Generic ack payload for signed control replies (`ok` / error text).
public struct ServiceAckDTO: Codable, Sendable, Hashable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String = "ok") {
        self.ok = ok
        self.message = message
    }

    public static let ok = ServiceAckDTO(ok: true, message: "ok")

    public static func error(_ message: String) -> ServiceAckDTO {
        ServiceAckDTO(ok: false, message: message)
    }
}

/// Auth payload for peer endpoint handoff (endpoint travels as NSXPC object separately).
public struct PeerHandoffAuthDTO: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case fetchMCPPeer
        case installMCPPeer
        case installDockerHelperPeer
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// Cancel an in-flight Agent turn.
public struct CancelTurnRequestDTO: Codable, Sendable, Hashable {
    public let turnID: String

    public init(turnID: String) {
        self.turnID = turnID
    }
}

/// Connectivity ping body.
public struct ServicePingDTO: Codable, Sendable, Hashable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Authenticated envelope. `signature` is HMAC-SHA256 hex over canonical bytes (v1).
public struct ServiceMessage: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let from: DerrickServiceID
    public let to: DerrickServiceID
    public let type: ServiceMessageType
    public let principal: ServicePrincipal
    public let correlationId: String?
    public let payloadJSON: Data
    public var signature: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        from: DerrickServiceID,
        to: DerrickServiceID,
        type: ServiceMessageType,
        principal: ServicePrincipal,
        correlationId: String? = nil,
        payloadJSON: Data = Data("{}".utf8),
        signature: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.from = from
        self.to = to
        self.type = type
        self.principal = principal
        self.correlationId = correlationId
        self.payloadJSON = payloadJSON
        self.signature = signature
    }
}

/// Job fire modes owned by JobService.
public enum JobFireKind: String, Codable, Sendable, Hashable {
    case runTool
    case wakeAgent
    case runToolThenWake
}
