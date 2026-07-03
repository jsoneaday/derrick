import Foundation
@_exported import MemorySystem

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

public struct AgentRequest: Hashable, Sendable {
    public let messages: [AgentMessage]
    public let temperature: Double?

    public init(messages: [AgentMessage], temperature: Double? = nil) {
        self.messages = messages
        self.temperature = temperature
    }

    public static func prompt(_ content: String, system: String? = nil, temperature: Double? = nil) -> Self {
        var messages: [AgentMessage] = []
        if let system {
            messages.append(.init(role: .system, content: system))
        }
        messages.append(.init(role: .user, content: content))
        return Self(messages: messages, temperature: temperature)
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
