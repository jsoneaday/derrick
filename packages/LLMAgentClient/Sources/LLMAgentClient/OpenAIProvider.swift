import Foundation

public enum OpenAIModel: String, CaseIterable, Codable, Sendable, AgentModel {
    case gpt54Mini = "gpt-5.4-mini"
    case gpt54 = "gpt-5.4"
    case gpt55 = "gpt-5.5"
    /// GPT-5.6 capability tiers (generation 5.6).
    case gpt56Sol = "gpt-5.6-sol"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt56Luna = "gpt-5.6-luna"

    public var id: AgentModelID {
        .init(provider: "openai", name: rawValue)
    }

    public var maxSupportedContextTokens: Int {
        400_000
    }

    public var maxIdealContextTokens: Int {
        200_000
    }

    /// Approximate list prices (USD / 1M tokens). Update when OpenAI changes rates.
    public var tokenPricing: ModelTokenPricing {
        switch self {
        case .gpt54Mini:
            return ModelTokenPricing(inputUSDPer1MTokens: 0.25, outputUSDPer1MTokens: 2.00)
        case .gpt54:
            return ModelTokenPricing(inputUSDPer1MTokens: 1.25, outputUSDPer1MTokens: 10.00)
        case .gpt55:
            return ModelTokenPricing(inputUSDPer1MTokens: 1.25, outputUSDPer1MTokens: 10.00)
        case .gpt56Luna:
            return ModelTokenPricing(inputUSDPer1MTokens: 0.50, outputUSDPer1MTokens: 4.00)
        case .gpt56Terra:
            return ModelTokenPricing(inputUSDPer1MTokens: 1.25, outputUSDPer1MTokens: 10.00)
        case .gpt56Sol:
            return ModelTokenPricing(inputUSDPer1MTokens: 2.50, outputUSDPer1MTokens: 15.00)
        }
    }
}

public struct OpenAIProvider: AgentProvider {
    public let apiKey: String
    public let transport: any HTTPTransport

    public init(apiKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func stream(_ request: AgentRequest, model: OpenAIModel) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try encode(OpenAIStreamRequest(
                        model: model.rawValue,
                        messages: request.messages,
                        temperature: request.temperature,
                        responseSchema: request.responseSchema
                    ))

                    let (bytes, response) = try await transport.bytes(for: urlRequest)
                    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        let errorString = String(decoding: errorData, as: UTF8.self)
                        throw AgentError.httpStatus(httpResponse.statusCode, errorString)
                    }
                    try validate(response: response)

                    for try await event in SSEDecoder(bytes: bytes).events {
                        for streamEvent in try openAIStreamEvents(from: event) {
                            continuation.yield(streamEvent)
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

struct OpenAIStreamRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let stream: Bool
    let temperature: Double?
    let responseFormat: OpenAIResponseFormat?
    let streamOptions: OpenAIStreamOptions?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case responseFormat = "response_format"
        case streamOptions = "stream_options"
    }

    init(model: String, messages: [AgentMessage], temperature: Double?, responseSchema: AgentSchema?) {
        self.model = model
        self.messages = messages.map(OpenAIMessage.init)
        self.stream = true
        self.streamOptions = OpenAIStreamOptions(includeUsage: true)
        
        // OpenAI's reasoning-class models (GPT-5 series) lock temperature internally and reject manual settings with HTTP 400.
        if model.contains("gpt-5") {
            self.temperature = nil
        } else {
            self.temperature = temperature
        }
        
        if let responseSchema {
            self.responseFormat = OpenAIResponseFormat(
                type: "json_schema",
                jsonSchema: OpenAIJSONSchemaWrapper(
                    name: "agent_response",
                    strict: true,
                    schema: OpenAISchema(from: responseSchema)
                )
            )
        } else {
            self.responseFormat = nil
        }
    }
}

struct OpenAIResponseFormat: Encodable {
    let type: String
    let jsonSchema: OpenAIJSONSchemaWrapper?

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

struct OpenAIJSONSchemaWrapper: Encodable {
    let name: String
    let strict: Bool
    let schema: OpenAISchema
}

enum OpenAISchemaType: Encodable, Equatable {
    case single(String)
    case union([String])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let type):
            try container.encode(type)
        case .union(let types):
            try container.encode(types)
        }
    }
}

final class OpenAISchema: Encodable, Equatable {
    let type: OpenAISchemaType
    let properties: [String: OpenAISchema]?
    let required: [String]?
    let items: OpenAISchema?
    let description: String?
    let additionalProperties: Bool?
    
    let isNullable: Bool
    let baseType: String

    static func == (lhs: OpenAISchema, rhs: OpenAISchema) -> Bool {
        lhs.type == rhs.type &&
        lhs.properties == rhs.properties &&
        lhs.required == rhs.required &&
        lhs.items == rhs.items &&
        lhs.description == rhs.description &&
        lhs.additionalProperties == rhs.additionalProperties &&
        lhs.isNullable == rhs.isNullable &&
        lhs.baseType == rhs.baseType
    }

    enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case items
        case description
        case additionalProperties = "additionalProperties"
        case anyOf = "anyOf"
    }

    init(from agentSchema: AgentSchema, isNullable: Bool = false) {
        self.isNullable = isNullable
        
        switch agentSchema.type {
        case .object:
            self.baseType = "object"
        case .array:
            self.baseType = "array"
        case .string:
            self.baseType = "string"
        case .number:
            self.baseType = "number"
        case .integer:
            self.baseType = "integer"
        case .boolean:
            self.baseType = "boolean"
        }

        self.type = .single(self.baseType)

        if let properties = agentSchema.properties {
            var mapped: [String: OpenAISchema] = [:]
            for (key, childSchema) in properties {
                let nullable = (key != "status" && key != "invocations")
                mapped[key] = OpenAISchema(from: childSchema, isNullable: nullable)
            }
            self.properties = mapped
            self.required = Array(properties.keys).sorted()
            self.additionalProperties = false
        } else {
            self.properties = nil
            self.required = nil
            self.additionalProperties = nil
        }

        if let items = agentSchema.items {
            self.items = OpenAISchema(from: items, isNullable: false)
        } else {
            self.items = nil
        }

        self.description = agentSchema.description
    }

    func encode(to encoder: Encoder) throws {
        if isNullable {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let valueSchema = OpenAIValueSchema(
                type: type,
                properties: properties,
                required: required,
                items: items,
                description: description,
                additionalProperties: additionalProperties
            )
            let nullSchema = OpenAINullSchema()
            let subSchemas: [OpenAISubSchema] = [
                .value(valueSchema),
                .null(nullSchema)
            ]
            try container.encode(subSchemas, forKey: .anyOf)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(properties, forKey: .properties)
            try container.encodeIfPresent(required, forKey: .required)
            try container.encodeIfPresent(items, forKey: .items)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(additionalProperties, forKey: .additionalProperties)
        }
    }
}

private enum OpenAISubSchema: Encodable {
    case value(OpenAIValueSchema)
    case null(OpenAINullSchema)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .value(let schema):
            try container.encode(schema)
        case .null(let schema):
            try container.encode(schema)
        }
    }
}

private struct OpenAIValueSchema: Encodable {
    let type: OpenAISchemaType
    let properties: [String: OpenAISchema]?
    let required: [String]?
    let items: OpenAISchema?
    let description: String?
    let additionalProperties: Bool?
}

private struct OpenAINullSchema: Encodable {
    let type: String = "null"
}

struct OpenAIMessage: Encodable {
    let role: String
    let content: String

    init(_ message: AgentMessage) {
        role = message.role.rawValue
        content = message.content
    }
}

struct OpenAIStreamOptions: Encodable {
    let includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct OpenAIStreamChunk: Decodable {
    let choices: [Choice]
    let usage: OpenAIUsage?

    struct Choice: Decodable {
        let delta: Delta?
    }

    struct Delta: Decodable {
        let content: String?
    }
}

private struct OpenAIUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// Parses OpenAI SSE payloads into text deltas and optional usage (when `stream_options.include_usage` is set).
func openAIStreamEvents(from event: String) throws -> [AgentStreamEvent] {
    var events: [AgentStreamEvent] = []
    for payload in event.split(whereSeparator: \.isNewline).map(String.init).filter({ !$0.isEmpty }) {
        let normalized: String
        if payload.hasPrefix("data:") {
            normalized = payload.dropFirst(5).trimmingCharacters(in: .whitespaces)
        } else {
            normalized = payload
        }

        if normalized == "[DONE]" {
            return events
        }

        let chunk = try decode(OpenAIStreamChunk.self, from: Data(normalized.utf8))
        if let text = chunk.choices.first?.delta?.content, !text.isEmpty {
            events.append(.text(text))
        }
        if let usage = chunk.usage {
            let prompt = usage.promptTokens ?? 0
            let completion = usage.completionTokens ?? 0
            let total = usage.totalTokens ?? (prompt + completion)
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

/// Backward-compatible text-only helper for tests.
func openAITextChunks(from event: String) throws -> [String] {
    try openAIStreamEvents(from: event).compactMap {
        if case .text(let t) = $0 { return t }
        return nil
    }
}
