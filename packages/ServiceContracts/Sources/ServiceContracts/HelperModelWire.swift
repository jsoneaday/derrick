import Foundation

/// Cross-process helper LLM selection (script reviewer, etc.).
/// Provider matches `LLMProviderChoice.rawValue` (`openai` / `google`);
/// model is the provider API model id (`OpenAIModel` / `GeminiModel` rawValue).
public struct HelperModelWire: Codable, Sendable, Hashable {
    public let provider: String
    public let model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    public static func encodeJSON(_ wire: HelperModelWire) throws -> String {
        let data = try JSONEncoder.service.encode(wire)
        guard let s = String(data: data, encoding: .utf8) else {
            throw HelperModelWireError.encodeFailed
        }
        return s
    }

    public static func decodeJSON(_ json: String) throws -> HelperModelWire {
        guard let data = json.data(using: .utf8) else {
            throw HelperModelWireError.decodeFailed
        }
        return try JSONDecoder.service.decode(HelperModelWire.self, from: data)
    }
}

public enum HelperModelWireError: Error, LocalizedError {
    case encodeFailed
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .encodeFailed: return "Failed to encode helper model wire JSON."
        case .decodeFailed: return "Failed to decode helper model wire JSON."
        }
    }
}
