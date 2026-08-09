import Foundation

/// How turn output is delivered to the client.
public enum AgentTurnDelivery: String, Codable, Sendable, Hashable {
    /// Stream chunks into the active chat (default).
    case chatStream
    /// Scheduled job wake: collect completion, notify via derrickd (no chat stream).
    case jobResultModal
}

/// Request to run one user-facing conversation turn in AgentService.
public struct AgentTurnRequest: Codable, Sendable, Hashable {
    public let turnID: String
    public let sessionID: String?
    public let prompt: String
    public let apiKey: String
    /// Encoded `LLMModelChoice` JSON (SharedAgentRuntime type).
    public let modelJSON: Data
    public let applicationName: String
    public let delivery: AgentTurnDelivery
    public let jobID: String?
    public let parentSessionID: String?

    public init(
        turnID: String = UUID().uuidString,
        sessionID: String? = nil,
        prompt: String,
        apiKey: String,
        modelJSON: Data,
        applicationName: String = DerrickAppSupport.defaultApplicationName,
        delivery: AgentTurnDelivery = .chatStream,
        jobID: String? = nil,
        parentSessionID: String? = nil
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.prompt = prompt
        self.apiKey = apiKey
        self.modelJSON = modelJSON
        self.applicationName = applicationName
        self.delivery = delivery
        self.jobID = jobID
        self.parentSessionID = parentSessionID
    }
}

/// Immediate ack from `startTurn` (chunks arrive on the client sink).
public struct AgentTurnAccepted: Codable, Sendable, Hashable {
    public let ok: Bool
    public let turnID: String
    public let sessionID: String
    public let message: String

    public init(ok: Bool, turnID: String, sessionID: String, message: String) {
        self.ok = ok
        self.turnID = turnID
        self.sessionID = sessionID
        self.message = message
    }
}

/// One streamed chunk (mirrors AgentResponseNextChunk fields for XPC JSON).
public struct AgentTurnChunkDTO: Codable, Sendable, Hashable {
    public let turnID: String
    public let status: String
    public let chunk: String?
    public let toolName: String?

    public init(turnID: String, status: String, chunk: String? = nil, toolName: String? = nil) {
        self.turnID = turnID
        self.status = status
        self.chunk = chunk
        self.toolName = toolName
    }
}

public struct AgentTurnErrorDTO: Codable, Sendable, Hashable {
    public let turnID: String
    public let message: String
    public let code: String?

    public init(turnID: String, message: String, code: String? = nil) {
        self.turnID = turnID
        self.message = message
        self.code = code
    }
}
