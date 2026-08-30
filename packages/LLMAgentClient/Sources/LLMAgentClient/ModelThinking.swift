import Foundation

/// Provider wire format for thinking / reasoning controls.
public enum ModelThinkingWire: Hashable, Codable, Sendable {
    case openAIReasoningEffort(String)
    case geminiThinkingLevel(String)
    case geminiThinkingBudget(Int)
}

/// One selectable thinking / reasoning setting for a specific model.
public struct ModelThinkingOption: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let wire: ModelThinkingWire

    public init(id: String, displayName: String, wire: ModelThinkingWire) {
        self.id = id
        self.displayName = displayName
        self.wire = wire
    }
}

extension OpenAIModel {
    private enum ReasoningEffort: String, CaseIterable {
        case none
        case low
        case medium
        case high
        case xhigh
        case max

        var displayName: String {
            switch self {
            case .none: return "None"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .xhigh: return "Extra High"
            case .max: return "Max"
            }
        }
    }

    public var thinkingOptions: [ModelThinkingOption] {
        let efforts: [ReasoningEffort]
        switch self {
        case .gpt54Mini:
            efforts = [.none, .low, .medium, .high]
        case .gpt54, .gpt55:
            efforts = [.none, .low, .medium, .high, .xhigh]
        case .gpt56Luna:
            efforts = [.none, .low, .medium, .high]
        case .gpt56Terra:
            efforts = [.none, .low, .medium, .high, .xhigh]
        case .gpt56Sol:
            efforts = [.none, .low, .medium, .high, .xhigh, .max]
        }
        return efforts.map { effort in
            ModelThinkingOption(
                id: effort.rawValue,
                displayName: effort.displayName,
                wire: .openAIReasoningEffort(effort.rawValue)
            )
        }
    }

    public var defaultThinkingOption: ModelThinkingOption {
        thinkingOptions.first { $0.id == ReasoningEffort.medium.rawValue }
            ?? thinkingOptions[0]
    }
}

extension GeminiModel {
    private enum ThinkingLevel: String, CaseIterable {
        case minimal
        case low
        case medium
        case high

        var displayName: String {
            rawValue.capitalized
        }

        var wireValue: String {
            rawValue.uppercased()
        }
    }

    public var thinkingOptions: [ModelThinkingOption] {
        switch self {
        case .gemini25FlashLite:
            return [
                ModelThinkingOption(id: "off", displayName: "Off", wire: .geminiThinkingBudget(0)),
                ModelThinkingOption(id: "dynamic", displayName: "Dynamic", wire: .geminiThinkingBudget(-1)),
                ModelThinkingOption(id: "light", displayName: "Light", wire: .geminiThinkingBudget(1_024)),
                ModelThinkingOption(id: "standard", displayName: "Standard", wire: .geminiThinkingBudget(4_096)),
                ModelThinkingOption(id: "deep", displayName: "Deep", wire: .geminiThinkingBudget(8_192)),
            ]
        case .gemini31FlashLite:
            return Self.levelOptions([.minimal, .low, .medium, .high])
        case .gemini37Flash:
            return Self.levelOptions([.low, .medium, .high])
        }
    }

    public var defaultThinkingOption: ModelThinkingOption {
        switch self {
        case .gemini25FlashLite:
            return thinkingOptions.first { $0.id == "off" } ?? thinkingOptions[0]
        case .gemini31FlashLite:
            return thinkingOptions.first { $0.id == ThinkingLevel.minimal.rawValue } ?? thinkingOptions[0]
        case .gemini37Flash:
            return thinkingOptions.first { $0.id == ThinkingLevel.medium.rawValue } ?? thinkingOptions[0]
        }
    }

    private static func levelOptions(_ levels: [ThinkingLevel]) -> [ModelThinkingOption] {
        levels.map { level in
            ModelThinkingOption(
                id: level.rawValue,
                displayName: level.displayName,
                wire: .geminiThinkingLevel(level.wireValue)
            )
        }
    }
}
