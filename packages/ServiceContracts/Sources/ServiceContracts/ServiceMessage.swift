import Foundation

/// Cross-service command/event types (payload is JSON object as Data).
public enum ServiceMessageType: String, Codable, Sendable, Hashable {
    // Health / control
    case health
    // Jobs
    case createJob
    case cancelJob
    case jobDue
    case jobTerminal
    // Agents
    case wakeAgent
    case injectUserMessage
    // MCP
    case runTool
    // Webhook ack
    case webhookAccepted
    case webhookRejected
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
