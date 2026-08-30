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
    /// Encoded `ModelThinkingOption` JSON from LLMAgentClient (optional).
    public let thinkingJSON: Data?
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
        thinkingJSON: Data? = nil,
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
        self.thinkingJSON = thinkingJSON
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
    public let sessionID: String?
    public let status: String
    public let chunk: String?
    public let toolName: String?
    public let isProgress: Bool

    public init(
        turnID: String,
        sessionID: String? = nil,
        status: String,
        chunk: String? = nil,
        toolName: String? = nil,
        isProgress: Bool = false
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.status = status
        self.chunk = chunk
        self.toolName = toolName
        self.isProgress = isProgress
    }

    enum CodingKeys: String, CodingKey {
        case turnID
        case sessionID
        case status
        case chunk
        case toolName
        case isProgress
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try container.decode(String.self, forKey: .turnID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        status = try container.decode(String.self, forKey: .status)
        chunk = try container.decodeIfPresent(String.self, forKey: .chunk)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        isProgress = try container.decodeIfPresent(Bool.self, forKey: .isProgress) ?? false
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
