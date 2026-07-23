import Foundation
@_exported import MemorySystem
import MCP

public struct AgentMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public final class AgentSchema: Codable, Sendable {
    public enum SchemaType: String, Codable, Sendable {
        case object = "OBJECT"
        case array = "ARRAY"
        case string = "STRING"
        case number = "NUMBER"
        case integer = "INTEGER"
        case boolean = "BOOLEAN"
    }

    public let type: SchemaType
    public let properties: [String: AgentSchema]?
    public let required: [String]?
    public let items: AgentSchema?
    public let description: String?

    public init(
        type: SchemaType,
        properties: [String: AgentSchema]? = nil,
        required: [String]? = nil,
        items: AgentSchema? = nil,
        description: String? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.items = items
        self.description = description
    }
}

extension AgentSchema: Hashable {
    public static func == (lhs: AgentSchema, rhs: AgentSchema) -> Bool {
        lhs.type == rhs.type &&
        lhs.properties == rhs.properties &&
        lhs.required == rhs.required &&
        lhs.items == rhs.items &&
        lhs.description == rhs.description
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(properties)
        hasher.combine(required)
        hasher.combine(items)
        hasher.combine(description)
    }
}

public struct AgentRequest: Hashable, Sendable {
    public let messages: [AgentMessage]
    public let temperature: Double?
    public let responseSchema: AgentSchema?

    public init(messages: [AgentMessage], temperature: Double? = nil, responseSchema: AgentSchema? = nil) {
        self.messages = messages
        self.temperature = temperature
        self.responseSchema = responseSchema
    }

    public static func prompt(_ content: String, system: String? = nil, temperature: Double? = nil, responseSchema: AgentSchema? = nil) -> Self {
        var messages: [AgentMessage] = []
        if let system {
            messages.append(.init(role: .system, content: system))
        }
        messages.append(.init(role: .user, content: content))
        return Self(messages: messages, temperature: temperature, responseSchema: responseSchema)
    }
}

public enum AgentResponseStatus: String, Decodable, Encodable, Sendable {
    case thinking = "thinking"
    case toolCall = "tool_call"
    case toolBatch = "tool_batch"
    case complete = "complete"
}

public func agentResponseStatusLabel(status: String) -> String {
    if status == "complete" {
        return "Complete"
    } else if status == "tool_call" {
        return "Tool Call"
    } else if status == "tool_batch" {
        return "Tool Batch"
    } else {
        return "Thinking"
    }
}

/// During streaming provides the next status (e.g. thinking, tool_call, etc) and the next chunk of text from llm
public struct AgentResponseNextChunk: Decodable, Encodable, Sendable {
    public let status: AgentResponseStatus
    public let toolName: String?
    public let chunk: String?
    
    public init(status: AgentResponseStatus, chunk: String? = nil, toolName: String? = nil) {
        self.status = status
        self.toolName = toolName
        self.chunk = chunk
    }
}

/// Notice most of the fields and subfields are nillable, except for status.
/// This is done deliberately to allow downstream partial deserialization in chunks.
public struct AgentResponse: Decodable, Encodable, Sendable {
    public let status: AgentResponseStatus
    public let thought: String?
    public let assistantResponse: String?
    public let toolCall: ToolCall?
    public let toolBatch: ToolBatch?
    
    enum CodingKeys: String, Encodable, CodingKey {
        case status
        case thought = "thought"
        case assistantResponse = "assistant_response"
        case toolCall = "tool_call"
        case toolBatch = "tool_batch"
    }
    
    public struct ToolCall: Decodable, Encodable, Sendable {
        public let toolName: String?
        public let arguments: String?
        
        enum CodingKeys: String, Encodable, CodingKey {
            case toolName = "tool_name"
            case arguments
        }
    }
    
    public struct ToolBatch: Decodable, Encodable, Sendable {
        public let tools: [ToolCall]?
    }
}

public struct AgentModelID: Hashable, Codable, Sendable {
    public let provider: String
    public let name: String

    public init(provider: String, name: String) {
        self.provider = provider
        self.name = name
    }

    public var rawValue: String {
        name
    }
}

public protocol AgentModel: Hashable, Codable, Sendable {
    var id: AgentModelID { get }
    var maxSupportedContextTokens: Int { get }
    var maxIdealContextTokens: Int { get }
}

public protocol AgentProvider: Sendable {
    associatedtype Model: AgentModel

    func stream(_ request: AgentRequest, model: Model) -> AsyncThrowingStream<String, Error>
}

public struct AgentClient<Provider: AgentProvider>: Sendable {
    public let provider: Provider

    public init(provider: Provider) {
        self.provider = provider
    }

    public func stream(_ request: AgentRequest, model: Provider.Model) -> AsyncThrowingStream<String, Error> {
        provider.stream(request, model: model)
    }
}

public protocol HTTPTransport: Sendable {
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }
}

public enum AgentError: Error, Sendable {
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case emptyResponse
    case requestEncodingFailed(String)
    case responseDecodingFailed(String)
}

extension AgentError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        description
    }

    public var description: String {
        switch self {
        case .invalidHTTPResponse:
            return "The server returned a non-HTTP response."
        case .httpStatus(let statusCode, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                return "HTTP \(statusCode)."
            }
            return "HTTP \(statusCode): \(trimmedBody)"
        case .emptyResponse:
            return "The model returned no streamed text."
        case .requestEncodingFailed(let message):
            return "Failed to encode request: \(message)"
        case .responseDecodingFailed(let message):
            return "Failed to decode response: \(message)"
        }
    }
}

public typealias OpenAIAgentClient = AgentClient<OpenAIProvider>
public typealias GeminiAgentClient = AgentClient<GeminiProvider>
