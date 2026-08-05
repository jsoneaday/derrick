import Foundation
import LLMAgentClient
import ServiceContracts

enum LLMProviderChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case google
    case openai

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var apiKeyName: String {
        switch self {
        case .google:
            return "Gemini API Key"
        case .openai:
            return "OpenAI API Key"
        }
    }

    var apiKeyEnvironmentKeys: [String] {
        switch self {
        case .google:
            return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .openai:
            return ["OPENAI_API_KEY"]
        }
    }

    var secretAccount: String {
        "\(rawValue)-api-key"
    }

    var models: [LLMModelChoice] {
        switch self {
        case .google:
            return GeminiModel.allCases.map { .gemini($0) }
        case .openai:
            return OpenAIModel.allCases.map { .openai($0) }
        }
    }

    var defaultModel: LLMModelChoice {
        switch self {
        case .google:
            return .gemini(.gemini31FlashLite)
        case .openai:
            return .openai(.gpt56Luna)
        }
    }
}

enum LLMModelChoice: Hashable, Identifiable, Codable, Sendable {
    case gemini(GeminiModel)
    case openai(OpenAIModel)

    static let allCases: [LLMModelChoice] = [
        .gemini(.gemini25FlashLite),
        .gemini(.gemini31FlashLite),
        .openai(.gpt54Mini),
        .openai(.gpt54),
        .openai(.gpt55),
        .openai(.gpt56Luna),
        .openai(.gpt56Terra),
        .openai(.gpt56Sol)
    ]

    /// Default for summarizer, Python reviewer, and conversation UI preselection.
    static let defaultHelperModel: LLMModelChoice = .openai(.gpt56Luna)

    var id: String {
        switch self {
        case .gemini(let model):
            return "gemini:\(model.rawValue)"
        case .openai(let model):
            return "openai:\(model.rawValue)"
        }
    }

    var provider: LLMProviderChoice {
        switch self {
        case .gemini:
            return .google
        case .openai:
            return .openai
        }
    }

    var displayName: String {
        switch self {
        case .gemini(let model):
            return model.rawValue
        case .openai(let model):
            return model.rawValue
        }
    }

    var helperDisplayName: String {
        "\(provider.displayName) · \(displayName)"
    }

    var maxSupportedContextTokens: Int {
        switch self {
        case .gemini(let model):
            return model.maxSupportedContextTokens
        case .openai(let model):
            return model.maxSupportedContextTokens
        }
    }

    var maxIdealContextTokens: Int {
        switch self {
        case .gemini(let model):
            return model.maxIdealContextTokens
        case .openai(let model):
            return model.maxIdealContextTokens
        }
    }

    var tokenPricing: ModelTokenPricing {
        switch self {
        case .gemini(let model):
            return model.tokenPricing
        case .openai(let model):
            return model.tokenPricing
        }
    }

    /// Wire format for MCPService / cross-process helper model handoff.
    var helperModelWire: HelperModelWire {
        switch self {
        case .gemini(let model):
            return HelperModelWire(provider: LLMProviderChoice.google.rawValue, model: model.rawValue)
        case .openai(let model):
            return HelperModelWire(provider: LLMProviderChoice.openai.rawValue, model: model.rawValue)
        }
    }

    func encodeHelperModelWireJSON() throws -> String {
        try HelperModelWire.encodeJSON(helperModelWire)
    }
}
