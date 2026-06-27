import Foundation

public enum OpenAIModel: String, CaseIterable, Codable, Sendable, AgentModel {
    case gpt5Mini = "gpt-5-mini"

    public var id: AgentModelID {
        .init(provider: "openai", name: rawValue)
    }
}

public struct OpenAIProvider: AgentProvider {
    public let apiKey: String
    public let transport: any HTTPTransport

    public init(apiKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func stream(_ request: AgentRequest, model: OpenAIModel) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try encode(OpenAIStreamRequest(model: model.rawValue, messages: request.messages, temperature: request.temperature))

                    let (bytes, response) = try await transport.bytes(for: urlRequest)
                    try validate(response: response)

                    for try await event in SSEDecoder(bytes: bytes).events {
                        if event == "[DONE]" {
                            continuation.finish()
                            return
                        }

                        let chunk = try decode(OpenAIStreamChunk.self, from: Data(event.utf8))
                        if let text = chunk.choices.first?.delta.content, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct OpenAIStreamRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let stream: Bool
    let temperature: Double?

    init(model: String, messages: [AgentMessage], temperature: Double?) {
        self.model = model
        self.messages = messages.map(OpenAIMessage.init)
        self.stream = true
        self.temperature = temperature
    }
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: String

    init(_ message: AgentMessage) {
        role = message.role.rawValue
        content = message.content
    }
}

private struct OpenAIStreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
    }

    struct Delta: Decodable {
        let content: String?
    }
}
