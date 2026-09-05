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
