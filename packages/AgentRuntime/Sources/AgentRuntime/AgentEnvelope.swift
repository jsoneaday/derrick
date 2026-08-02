import Foundation

/// Who originated an envelope.
public enum EnvelopeSource: Hashable, Codable, Sendable {
    case user
    case system
    case agent(AgentRef)
    /// Reserved for the job scheduler program (MA later).
    case job(jobID: String)
}

public enum EnvelopeKind: String, Codable, Sendable, Hashable {
    case userMessage
    case agentMessage
    case taskAssign
    case taskResult
    case control
    /// Reserved: job terminal → agent wake.
    case jobResult
}

/// Unit of work that can wake an agent turn.
public struct AgentEnvelope: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let correlationId: String?
    public let to: AgentRef
    public let from: EnvelopeSource
    public let kind: EnvelopeKind
    /// Agent-facing text body (keep small; large blobs via `payloadRef`).
    public let body: String
    public let payloadRef: String?
    public let replyTo: UUID?

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        correlationId: String? = nil,
        to: AgentRef,
        from: EnvelopeSource,
        kind: EnvelopeKind,
        body: String,
        payloadRef: String? = nil,
        replyTo: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.correlationId = correlationId
        self.to = to
        self.from = from
        self.kind = kind
        self.body = body
        self.payloadRef = payloadRef
        self.replyTo = replyTo
    }

    public static func userMessage(
        to: AgentRef,
        body: String,
        correlationId: String? = nil
    ) -> AgentEnvelope {
        AgentEnvelope(
            correlationId: correlationId,
            to: to,
            from: .user,
            kind: .userMessage,
            body: body
        )
    }

    public static func taskAssign(
        to: AgentRef,
        from parent: AgentRef,
        body: String,
        correlationId: String? = nil
    ) -> AgentEnvelope {
        AgentEnvelope(
            correlationId: correlationId,
            to: to,
            from: .agent(parent),
            kind: .taskAssign,
            body: body
        )
    }

    public static func taskResult(
        to parent: AgentRef,
        from worker: AgentRef,
        body: String,
        correlationId: String? = nil,
        replyTo: UUID? = nil
    ) -> AgentEnvelope {
        AgentEnvelope(
            correlationId: correlationId,
            to: parent,
            from: .agent(worker),
            kind: .taskResult,
            body: body,
            replyTo: replyTo
        )
    }
}
