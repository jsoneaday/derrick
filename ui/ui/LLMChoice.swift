import Foundation
import LLMAgentClient

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
            return .openai(.gpt5Mini)
        }
    }
}

enum LLMModelChoice: Hashable, Identifiable, Codable, Sendable {
    case gemini(GeminiModel)
    case openai(OpenAIModel)

    static let allCases: [LLMModelChoice] = [
        .gemini(.gemini25FlashLite),
        .gemini(.gemini31FlashLite),
        .openai(.gpt5Mini),
        .openai(.gpt54Mini),
        .openai(.gpt54),
        .openai(.gpt55)
    ]

    static let defaultHelperModel: LLMModelChoice = .gemini(.gemini31FlashLite)

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
}
