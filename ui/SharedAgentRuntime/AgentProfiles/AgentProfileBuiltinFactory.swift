import Foundation
import LLMAgentClient
import Structure

/// Built-in agent profiles with product-default models and thinking levels.
public enum AgentProfileBuiltinFactory {
    public static func all() throws -> [AgentProfile] {
        let lunaMedium = try wire(model: .openai(.gpt6Luna), thinkingID: "medium")
        let lunaHigh = try wire(model: .openai(.gpt6Luna), thinkingID: "high")
        return [
            AgentProfile.orchestratorDefault(modelJSON: lunaHigh.modelJSON, thinkingJSON: lunaHigh.thinkingJSON),
            AgentProfile.developerDefault(modelJSON: lunaMedium.modelJSON, thinkingJSON: lunaMedium.thinkingJSON),
            AgentProfile.researcherDefault(modelJSON: lunaMedium.modelJSON, thinkingJSON: lunaMedium.thinkingJSON),
            AgentProfile.generalistDefault(modelJSON: lunaMedium.modelJSON, thinkingJSON: lunaMedium.thinkingJSON),
        ]
    }

    private struct Wire {
        let modelJSON: Data
        let thinkingJSON: Data
    }

    private static func wire(model: LLMModelChoice, thinkingID: String) throws -> Wire {
        guard let thinking = model.thinkingOptions.first(where: { $0.id == thinkingID }) else {
            throw AgentProfileBuiltinFactoryError.missingThinking(model: model.id, thinkingID: thinkingID)
        }
        return Wire(
            modelJSON: try JSONEncoder().encode(model),
            thinkingJSON: try JSONEncoder().encode(thinking)
        )
    }
}

public enum AgentProfileBuiltinFactoryError: Error, LocalizedError {
    case missingThinking(model: String, thinkingID: String)

    public var errorDescription: String? {
        switch self {
        case .missingThinking(let model, let thinkingID):
            return "Missing thinking option \(thinkingID) for model \(model)."
        }
    }
}
