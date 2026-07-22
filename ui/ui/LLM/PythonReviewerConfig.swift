//
//  PythonReviewerConfig.swift
//  ui
//
//  Created by David Choi on 7/21/26.
//

import Foundation
import MCPServer
import LLMAgentClient

actor ConfiguredPythonScriptReviewer: PythonScriptReviewer {
    nonisolated let name: String = "configured-python-script-reviewer"

    private let settings: LLMModelSettings

    init(settings: LLMModelSettings) {
        self.settings = settings
    }

    func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewAssessment {
        let selectedModel = await MainActor.run { settings.pythonScriptReviewerModel }
        guard let apiKey = await resolveAPIKey(for: selectedModel) else {
            await MainActor.run {
                debugLog(
                    "Helper reviewer model \(selectedModel.helperDisplayName) unavailable; using default Gemini reviewer."
                )
            }

            if let defaultReview = await defaultReviewerAssessment(for: args) {
                return defaultReview
            }

            throw NSError(
                domain: "ui",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No API key available for helper reviewer."]
            )
        }

        do {
            return try await review(args, model: selectedModel, apiKey: apiKey)
        } catch {
            await MainActor.run {
                debugLog(
                    "Helper reviewer model \(selectedModel.helperDisplayName) failed: \(error.localizedDescription)"
                )
                LLMFailureReporter.shared.report(
                    LLMFailureClassifier.classify(error, provider: selectedModel.provider)
                )
            }
            if let defaultReview = await defaultReviewerAssessment(for: args) {
                return defaultReview
            }
            throw error
        }
    }

    private func defaultReviewerAssessment(for args: PythonScriptExecutionArguments) async -> PythonScriptReviewAssessment? {
        guard let apiKey = await resolveAPIKey(for: .defaultHelperModel) else {
            return nil
        }

        do {
            return try await review(args, model: .defaultHelperModel, apiKey: apiKey)
        } catch {
            await MainActor.run {
                debugLog("Default helper reviewer failed: \(error.localizedDescription)")
                LLMFailureReporter.shared.report(
                    LLMFailureClassifier.classify(error, provider: LLMModelChoice.defaultHelperModel.provider)
                )
            }
            return nil
        }
    }

    private func review(
        _ args: PythonScriptExecutionArguments,
        model: LLMModelChoice,
        apiKey: String
    ) async throws -> PythonScriptReviewAssessment {
        switch model {
        case .gemini(let geminiModel):
            let reviewer = GeminiPythonScriptReviewer(apiKey: apiKey, model: geminiModel)
            return try await reviewer.review(args)
        case .openai(let openAIModel):
            let reviewer = OpenAIPythonScriptReviewer(apiKey: apiKey, model: openAIModel)
            return try await reviewer.review(args)
        }
    }

    private func resolveAPIKey(for model: LLMModelChoice) async -> String? {
        await MainActor.run {
            AppSecretResolver().resolve(
                account: model.provider.secretAccount,
                environmentKeys: model.provider.apiKeyEnvironmentKeys
            )
        }
    }
}
