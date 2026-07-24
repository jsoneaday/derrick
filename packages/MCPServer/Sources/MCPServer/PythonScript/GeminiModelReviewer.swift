//
//  GeminiModelReviewer.swift
//  MCPServer
//
//  Created by David Choi on 7/24/26.
//

import Foundation
import LLMAgentClient

public struct GeminiPythonScriptReviewer: PythonScriptReviewer {
    public let name: String
    private let model: GeminiModel
    private let client: GeminiAgentClient

    public init(apiKey: String, model: GeminiModel = .gemini25FlashLite) {
        self.name = "gemini-\(model.rawValue)"
        self.model = model
        self.client = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
    }

    public static func fromEnvironment(
        variable: String = "GEMINI_API_KEY",
        model: GeminiModel = .gemini25FlashLite
    ) -> GeminiPythonScriptReviewer? {
        guard let apiKey = ProcessInfo.processInfo.environment[variable], !apiKey.isEmpty else {
            return nil
        }
        return GeminiPythonScriptReviewer(apiKey: apiKey, model: model)
    }

    public func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewOutcome {
        let userContent = PythonScriptReviewerRuntime.reviewInput(from: args)
        let request = AgentRequest(
            messages: [
                .init(role: .system, content: ReviewerSystemPrompt),
                .init(role: .user, content: userContent)
            ],
            temperature: 0
        )
        let stream = client.stream(request, model: model)
        return try await PythonScriptReviewerRuntime.runStreamedReview(
            modelLabel: model.rawValue,
            args: args,
            stream: stream
        )
    }
}
