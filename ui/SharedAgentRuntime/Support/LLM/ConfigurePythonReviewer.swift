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

    func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewOutcome {
        let selectedModel = await MainActor.run { settings.pythonScriptReviewerModel }
        guard let apiKey = await resolveAPIKey(for: selectedModel) else {
            await MainActor.run {
                debugLog(
                    "Helper reviewer model \(selectedModel.helperDisplayName) unavailable; trying default helper reviewer."
                )
            }

            if let defaultReview = await defaultReviewerAssessment(for: args) {
                await MainActor.run {
                    debugLog("Default helper reviewer succeeded after primary model was unavailable.")
                    debugLog(defaultReview.timing.summaryLine)
                }
                return defaultReview
            }

            // Fail closed: no assessment means tool layer must deny execution.
            throw NSError(
                domain: "ui",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No API key available for helper reviewer."]
            )
        }

        do {
            let outcome = try await review(args, model: selectedModel, apiKey: apiKey)
            await MainActor.run {
                debugLog(outcome.timing.summaryLine)
            }
            return outcome
        } catch {
            // Primary failed (e.g. timeout). Try fallback quietly; only surface a user-facing
            // failure if fallback also fails. Otherwise the script can still run after a
            // successful fallback review, and a "Model Request Failed" modal is misleading.
            await MainActor.run {
                debugLog(
                    "Helper reviewer model \(selectedModel.helperDisplayName) failed: \(error.localizedDescription). Trying default helper reviewer."
                )
            }
            if let defaultReview = await defaultReviewerAssessment(for: args) {
                await MainActor.run {
                    debugLog("Default helper reviewer succeeded after primary failure.")
                    debugLog(defaultReview.timing.summaryLine)
                }
                return defaultReview
            }
            await MainActor.run {
                debugLog("Default helper reviewer also failed; denying review.")
                LLMFailureReporter.shared.report(
                    LLMFailureClassifier.classify(error, provider: selectedModel.provider)
                )
            }
            throw error
        }
    }

    private func defaultReviewerAssessment(for args: PythonScriptExecutionArguments) async -> PythonScriptReviewOutcome? {
        let defaultModel = LLMModelChoice.defaultHelperModel
        // Avoid a useless second call if primary is already the default helper.
        let selectedModel = await MainActor.run { settings.pythonScriptReviewerModel }
        if selectedModel == defaultModel {
            return nil
        }
        guard let apiKey = await resolveAPIKey(for: defaultModel) else {
            return nil
        }

        do {
            return try await review(args, model: defaultModel, apiKey: apiKey)
        } catch {
            await MainActor.run {
                debugLog("Default helper reviewer failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func review(
        _ args: PythonScriptExecutionArguments,
        model: LLMModelChoice,
        apiKey: String
    ) async throws -> PythonScriptReviewOutcome {
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
        if let key = await MainActor.run(body: {
            AppSecretResolver().resolve(
                account: model.provider.secretAccount,
                environmentKeys: model.provider.apiKeyEnvironmentKeys
            )
        }), !key.isEmpty {
            return key
        }
        // AgentService XPC process cannot read the UI keychain; use the turn-supplied key.
        return TurnProcessContext.effectiveAPIKey
    }
}
