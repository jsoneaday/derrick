import Foundation

public enum GeminiModel: String, CaseIterable, Codable, Sendable, AgentModel {
    case gemini25FlashLite = "gemini-2.5-flash-lite"
    case gemini31FlashLite = "gemini-3.1-flash-lite"
    case gemini37Flash = "gemini-3.7-flash"

    public var id: AgentModelID {
        .init(provider: "gemini", name: rawValue)
    }

    public var maxSupportedContextTokens: Int {
        switch self {
        case .gemini25FlashLite, .gemini31FlashLite, .gemini37Flash:
            return 1_048_576
        }
    }

    public var maxIdealContextTokens: Int {
        switch self {
        case .gemini25FlashLite:
            return 64_000
        case .gemini31FlashLite, .gemini37Flash:
            return 128_000
        }
    }

    /// Approximate list prices (USD / 1M tokens). Update when Google changes rates.
    public var tokenPricing: ModelTokenPricing {
        switch self {
        case .gemini25FlashLite, .gemini31FlashLite:
            return ModelTokenPricing(inputUSDPer1MTokens: 0.10, outputUSDPer1MTokens: 0.40)
        case .gemini37Flash:
            return ModelTokenPricing(inputUSDPer1MTokens: 1.50, outputUSDPer1MTokens: 7.50)
        }
    }
}

public struct GeminiProvider: AgentProvider {
    public let apiKey: String
    public let transport: any HTTPTransport

    public init(apiKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func stream(_ request: AgentRequest, model: GeminiModel) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        if let responseSchema = request.responseSchema {
            return streamJSON(request, model: model, responseSchema: responseSchema)
        }

        return AsyncThrowingStream { continuation in
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
                        for streamEvent in try geminiStreamEvents(from: event) {
                            if case .text = streamEvent { didYieldText = true }
                            continuation.yield(streamEvent)
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

    public func streamJSON(
        _ request: AgentRequest,
        model: GeminiModel,
        responseSchema: AgentSchema? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try geminiURL(for: model)
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try encode(GeminiJSONStreamRequest(
                        messages: request.messages,
                        temperature: request.temperature,
                        responseSchema: responseSchema
                    ))

                    let (bytes, response) = try await transport.bytes(for: urlRequest)
                    try validate(response: response)

                    var didYieldText = false
                    for try await event in SSEDecoder(bytes: bytes).events {
                        for streamEvent in try geminiStreamEvents(from: event) {
                            if case .text = streamEvent { didYieldText = true }
                            continuation.yield(streamEvent)
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
            let trimmed = event.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [try decode(GeminiStreamChunk.self, from: Data(trimmed.utf8))]
        }

        var chunks: [GeminiStreamChunk] = []
        for payload in payloads {
            chunks.append(try decode(GeminiStreamChunk.self, from: Data(payload.utf8)))
        }
        return chunks
    }
}

func geminiStreamEvents(from event: String) throws -> [AgentStreamEvent] {
    var events: [AgentStreamEvent] = []
    let payloads = event
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    let chunks: [GeminiStreamChunk]
    if payloads.isEmpty {
        chunks = []
    } else if payloads.count == 1 {
        chunks = [try decode(GeminiStreamChunk.self, from: Data(payloads[0].utf8))]
    } else {
        chunks = try payloads.map { try decode(GeminiStreamChunk.self, from: Data($0.utf8)) }
    }

    for chunk in chunks {
        if let text = chunk.candidates.first?.content.text, !text.isEmpty {
            events.append(.text(text))
        }
        if let usage = chunk.usageMetadata {
            let prompt = usage.promptTokenCount ?? 0
            let completion = usage.candidatesTokenCount ?? usage.totalTokenCount.map { max(0, $0 - prompt) } ?? 0
            let total = usage.totalTokenCount ?? (prompt + completion)
            if prompt > 0 || completion > 0 || total > 0 {
                events.append(
                    .usage(
                        AgentTokenUsage(
                            promptTokens: prompt,
                            completionTokens: completion,
                            totalTokens: total,
                            source: .providerAPI
                        )
                    )
                )
            }
        }
    }
    return events
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

struct GeminiJSONStreamRequest: Encodable {
    let systemInstruction: GeminiSystemInstruction?
    let contents: [GeminiContent]
    let generationConfig: GeminiJSONGenerationConfig

    init(messages: [AgentMessage], temperature: Double?, responseSchema: AgentSchema?) {
        let systemMessages = messages.filter { $0.role == .system }
        let chatMessages = messages.filter { $0.role != .system }

        let systemText = systemMessages.map(\.content).joined(separator: "\n")
        if !systemText.isEmpty {
            systemInstruction = GeminiSystemInstruction(parts: [GeminiPart(text: systemText)])
        } else {
            systemInstruction = nil
        }

        contents = chatMessages.map(GeminiContent.init)
        generationConfig = GeminiJSONGenerationConfig(temperature: temperature, responseSchema: responseSchema)
    }
}

struct GeminiJSONGenerationConfig: Encodable {
    let temperature: Double?
    let responseMimeType: String
    let responseSchema: AgentSchema?

    init(temperature: Double?, responseSchema: AgentSchema?) {
        self.temperature = temperature
        self.responseMimeType = "application/json"
        self.responseSchema = responseSchema
    }
}

struct GeminiSystemInstruction: Encodable {
    let parts: [GeminiPart]
}

private struct GeminiGenerationConfig: Encodable {
    let temperature: Double
}

struct GeminiContent: Encodable {
    let role: String
    let parts: [GeminiPart]

    init(_ message: AgentMessage) {
        role = message.role == .assistant ? "model" : "user"
        parts = [GeminiPart(text: message.content)]
    }
}

struct GeminiPart: Codable, Sendable {
    let text: String?
}

private struct GeminiStreamChunk: Decodable {
    let candidates: [Candidate]
    let usageMetadata: GeminiUsageMetadata?

    struct Candidate: Decodable {
        let content: GeminiStreamContent

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decodeIfPresent(GeminiStreamContent.self, forKey: .content)
                ?? GeminiStreamContent(parts: [])
        }

        private enum CodingKeys: String, CodingKey {
            case content
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidates = try container.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
        usageMetadata = try container.decodeIfPresent(GeminiUsageMetadata.self, forKey: .usageMetadata)
    }

    private enum CodingKeys: String, CodingKey {
        case candidates
        case usageMetadata
    }
}

private struct GeminiUsageMetadata: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
}

private struct GeminiStreamContent: Decodable {
    let parts: [GeminiPart]

    init(parts: [GeminiPart]) {
        self.parts = parts
    }

    var text: String? {
        parts.compactMap(\.text).joined().nilIfEmpty
    }
}
