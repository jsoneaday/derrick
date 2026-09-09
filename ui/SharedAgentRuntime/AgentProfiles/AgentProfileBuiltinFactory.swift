import Foundation
import LLMAgentClient
import Structure

/// Built-in agent profiles with product-default models and thinking levels.
public enum AgentProfileBuiltinFactory {
    public static func all() throws -> [AgentProfile] {
        let solHigh = try wire(model: .openai(.gpt56Sol), thinkingID: "high")
        let terraHigh = try wire(model: .openai(.gpt56Terra), thinkingID: "high")
        let lunaHigh = try wire(model: .openai(.gpt56Luna), thinkingID: "high")
        return [
            AgentProfile.orchestratorDefault(modelJSON: solHigh.modelJSON, thinkingJSON: solHigh.thinkingJSON),
            AgentProfile.developerDefault(modelJSON: terraHigh.modelJSON, thinkingJSON: terraHigh.thinkingJSON),
            AgentProfile.researcherDefault(modelJSON: terraHigh.modelJSON, thinkingJSON: terraHigh.thinkingJSON),
            AgentProfile.generalDefault(modelJSON: lunaHigh.modelJSON, thinkingJSON: lunaHigh.thinkingJSON),
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
