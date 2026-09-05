import Foundation

public enum PolicyInterceptionEvent: Sendable {
    case assistantChunk(AssistantChunkEvent)
    case assistantCompletion(AssistantCompletionEvent)
    case toolInvocation(ToolInvocationEvent)
    case toolResult(ToolResultEvent)
    case statusUpdate(StatusUpdateEvent)

    public var timestamp: Date {
        switch self {
        case .assistantChunk(let event): return event.timestamp
        case .assistantCompletion(let event): return event.timestamp
        case .toolInvocation(let event): return event.timestamp
        case .toolResult(let event): return event.timestamp
        case .statusUpdate(let event): return event.timestamp
        }
    }
}

public struct AssistantChunkEvent: Sendable, Hashable {
    public let eventID: String
    public let sessionID: String
    public let chunkIndex: Int
    public let content: String
    public let timestamp: Date

    public init(
        sessionID: String,
        chunkIndex: Int,
        content: String,
        timestamp: Date = .now
    ) {
        self.eventID = UUID().uuidString
        self.sessionID = sessionID
        self.chunkIndex = chunkIndex
        self.content = content
        self.timestamp = timestamp
    }
}

public struct AssistantCompletionEvent: Sendable, Hashable {
    public let eventID: String
    public let sessionID: String
    public let fullCompletion: String
    public let chunkCount: Int
    public let timestamp: Date

    public init(
        sessionID: String,
        fullCompletion: String,
        chunkCount: Int,
        timestamp: Date = .now
    ) {
        self.eventID = UUID().uuidString
        self.sessionID = sessionID
        self.fullCompletion = fullCompletion
        self.chunkCount = chunkCount
        self.timestamp = timestamp
    }
}

public struct ToolInvocationEvent: Sendable, Hashable {
    public let eventID: String
    public let sessionID: String
    public let toolName: String
    public let argumentsJSON: String
    public let timestamp: Date

    public init(
        sessionID: String,
        toolName: String,
        argumentsJSON: String,
        timestamp: Date = .now
    ) {
        self.eventID = UUID().uuidString
        self.sessionID = sessionID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.timestamp = timestamp
    }
}

public struct ToolResultEvent: Sendable, Hashable {
    public let eventID: String
    public let sessionID: String
    public let toolName: String
    public let resultJSON: String
    public let error: String?
    public let timestamp: Date

    public init(
        sessionID: String,
        toolName: String,
        resultJSON: String,
        error: String? = nil,
        timestamp: Date = .now
    ) {
        self.eventID = UUID().uuidString
        self.sessionID = sessionID
        self.toolName = toolName
        self.resultJSON = resultJSON
        self.error = error
        self.timestamp = timestamp
    }
}

public struct StatusUpdateEvent: Sendable, Hashable {
    public let eventID: String
    public let sessionID: String
    public let message: String
    public let timestamp: Date

    public init(
        sessionID: String,
        message: String,
        timestamp: Date = .now
    ) {
        self.eventID = UUID().uuidString
        self.sessionID = sessionID
        self.message = message
        self.timestamp = timestamp
    }
}
