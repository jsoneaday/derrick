//
//  OpenAIModelReviewer.swift
//  MCPServer
//
//  Created by David Choi on 7/24/26.
//

import Foundation
import LLMAgentClient

public struct OpenAIPythonScriptReviewer: PythonScriptReviewer {
    public let name: String
    private let model: OpenAIModel
    private let client: OpenAIAgentClient

    public init(apiKey: String, model: OpenAIModel = .gpt56Luna) {
        self.name = "openai-\(model.rawValue)"
        self.model = model
        self.client = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
    }

    public static func fromEnvironment(
        variable: String = "OPENAI_API_KEY",
        model: OpenAIModel = .gpt56Luna
    ) -> OpenAIPythonScriptReviewer? {
        guard let apiKey = ProcessInfo.processInfo.environment[variable], !apiKey.isEmpty else {
            return nil
        }
        return OpenAIPythonScriptReviewer(apiKey: apiKey, model: model)
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
