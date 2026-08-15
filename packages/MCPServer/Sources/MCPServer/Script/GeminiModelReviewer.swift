//
//  GeminiModelReviewer.swift
//  MCPServer
//
//  Created by David Choi on 7/24/26.
//

import Foundation
import LLMAgentClient

public struct GeminiScriptReviewer: ScriptReviewer {
    public let name: String
    private let model: GeminiModel
    private let client: GeminiAgentClient
    private let systemPrompt: String

    public init(
        apiKey: String,
        model: GeminiModel = .gemini25FlashLite,
        systemPrompt: String = ReviewerSystemPrompt
    ) {
        self.name = "gemini-\(model.rawValue)"
        self.model = model
        self.client = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
        self.systemPrompt = systemPrompt
    }

    public static func fromEnvironment(
        variable: String = "GEMINI_API_KEY",
        model: GeminiModel = .gemini25FlashLite
    ) -> GeminiScriptReviewer? {
        guard let apiKey = ProcessInfo.processInfo.environment[variable], !apiKey.isEmpty else {
            return nil
        }
        return GeminiScriptReviewer(apiKey: apiKey, model: model)
    }

    public func review(_ args: ScriptExecutionArguments) async throws -> ScriptReviewOutcome {
        let userContent = ScriptReviewerRuntime.reviewInput(from: args)
        let request = AgentRequest(
            messages: [
                .init(role: .system, content: systemPrompt),
                .init(role: .user, content: userContent)
            ],
            temperature: 0
        )
        let stream = client.stream(request, model: model)
        return try await ScriptReviewerRuntime.runStreamedReview(
            modelLabel: model.rawValue,
            args: args,
            stream: stream
        )
    }
}
