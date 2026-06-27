import Foundation

public enum GeminiModel: String, CaseIterable, Codable, Sendable, AgentModel {
    case gemini25FlashLite = "gemini-2.5-flash-lite"
    case gemini31FlashLite = "gemini-3.1-flash-lite"

    public var id: AgentModelID {
        .init(provider: "gemini", name: rawValue)
    }
}

public struct GeminiProvider: AgentProvider {
    public let apiKey: String
    public let transport: any HTTPTransport

    public init(apiKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func stream(_ request: AgentRequest, model: GeminiModel) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try geminiURL(for: model)
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try encode(GeminiStreamRequest(messages: request.messages, temperature: request.temperature))

                    let (bytes, response) = try await transport.bytes(for: urlRequest)
                    try validate(response: response)

                    var didYieldText = false
                    for try await event in SSEDecoder(bytes: bytes).events {
                        for chunk in try decodeGeminiChunks(from: event) {
                            if let text = chunk.candidates.first?.content.text, !text.isEmpty {
                                didYieldText = true
                                continuation.yield(text)
                            }
                        }
                    }

                    guard didYieldText else {
                        throw AgentError.emptyResponse
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

    private func geminiURL(for model: GeminiModel) throws -> URL {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):streamGenerateContent")!
        components.queryItems = [
            URLQueryItem(name: "alt", value: "sse"),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components.url else {
            throw AgentError.invalidHTTPResponse
        }
        return url
    }

    private func decodeGeminiChunks(from event: String) throws -> [GeminiStreamChunk] {
        let payloads = event
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if payloads.count <= 1 {
            return [try decode(GeminiStreamChunk.self, from: Data(event.utf8))]
        }

        var chunks: [GeminiStreamChunk] = []
        for payload in payloads {
            chunks.append(try decode(GeminiStreamChunk.self, from: Data(payload.utf8)))
        }
        return chunks
    }
}

private struct GeminiStreamRequest: Encodable {
    let systemInstruction: GeminiSystemInstruction?
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig?

    init(messages: [AgentMessage], temperature: Double?) {
        let systemMessages = messages.filter { $0.role == .system }
        let chatMessages = messages.filter { $0.role != .system }

        let systemText = systemMessages.map(\.content).joined(separator: "\n")
        if !systemText.isEmpty {
            systemInstruction = GeminiSystemInstruction(parts: [GeminiPart(text: systemText)])
        } else {
            systemInstruction = nil
        }

        contents = chatMessages.map(GeminiContent.init)
        generationConfig = temperature.map { GeminiGenerationConfig(temperature: $0) }
    }
}

private struct GeminiSystemInstruction: Encodable {
    let parts: [GeminiPart]
}

private struct GeminiGenerationConfig: Encodable {
    let temperature: Double
}

private struct GeminiContent: Encodable {
    let role: String
    let parts: [GeminiPart]

    init(_ message: AgentMessage) {
        role = message.role == .assistant ? "model" : "user"
        parts = [GeminiPart(text: message.content)]
    }
}

private struct GeminiPart: Codable, Sendable {
    let text: String?
}

private struct GeminiStreamChunk: Decodable {
    let candidates: [Candidate]

    struct Candidate: Decodable {
        let content: GeminiStreamContent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidates = try container.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case candidates
    }
}

private struct GeminiStreamContent: Decodable {
    let parts: [GeminiPart]

    var text: String? {
        parts.compactMap(\.text).joined().nilIfEmpty
    }
}
