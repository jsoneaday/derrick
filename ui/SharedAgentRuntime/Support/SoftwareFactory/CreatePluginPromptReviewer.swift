import Foundation
import LLMAgentClient
import ServiceContracts

struct CreatePluginPromptReview: Sendable, Hashable {
    var ok: Bool
    var summary: String
    var pluginDoes: String
    var chatDoes: String
    var questions: [String]
    var warnings: [String]

    var isSatisfied: Bool {
        ok && questions.isEmpty
    }
}

enum CreatePluginPromptReviewer {
    static func review(
        request: String,
        previous: CreatePluginPromptReview?,
        settings: LLMModelSettings
    ) async throws -> CreatePluginPromptReview {
        let selected = await MainActor.run { settings.scriptReviewerModel }
        return try await review(request: request, previous: previous, model: selected)
    }

    private static func review(
        request: String,
        previous: CreatePluginPromptReview?,
        model: LLMModelChoice
    ) async throws -> CreatePluginPromptReview {
        guard let apiKey = await resolveAPIKey(for: model), !apiKey.isEmpty else {
            throw NSError(
                domain: "CreatePluginPromptReviewer",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No API key available for the helper reviewer."]
            )
        }
        let system = (try? DerrickBundledText.load("create_plugin_prompt_review.md"))
            ?? "Review whether this request can be a complementary plugin. Return JSON with ok, summary, plugin_does, chat_does, questions, warnings."
        var user = "Request:\n\(request)"
        if let previous {
            let asked = previous.questions.joined(separator: "\n- ")
            user += """


            Previous review:
            \(previous.summary)
            plugin_does: \(previous.pluginDoes)
            chat_does: \(previous.chatDoes.isEmpty ? "(none)" : previous.chatDoes)
            """
            if !asked.isEmpty {
                user += "\nQuestions still open unless they answered them in the request:\n- \(asked)"
            }
        }
        let schema = AgentSchema(
            type: .object,
            properties: [
                "ok": AgentSchema(type: .boolean),
                "summary": AgentSchema(type: .string),
                "plugin_does": AgentSchema(type: .string),
                "chat_does": AgentSchema(type: .string),
                "questions": AgentSchema(type: .array, items: AgentSchema(type: .string)),
                "warnings": AgentSchema(type: .array, items: AgentSchema(type: .string)),
            ],
            required: ["ok", "summary", "plugin_does"]
        )
        let agentRequest = AgentRequest.prompt(user, system: system, temperature: 0, responseSchema: schema)
        let raw = try await streamResponse(agentRequest, model: model, apiKey: apiKey)
        return parse(raw, fallbackRequest: request)
    }

    private static func parse(_ raw: String, fallbackRequest: String) -> CreatePluginPromptReview {
        let json: String
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") {
            json = String(raw[start...end])
        } else {
            json = raw
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CreatePluginPromptReview(
                ok: false,
                summary: "The helper could not read that request. Try again in a shorter sentence.",
                pluginDoes: fallbackRequest,
                chatDoes: "",
                questions: [],
                warnings: []
            )
        }
        let stringList: ([Any]) -> [String] = { items in
            items.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let questions = stringList(object["questions"] as? [Any] ?? [])
        let warnings = stringList(object["warnings"] as? [Any] ?? [])
        let summary = (object["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pluginDoes = (object["plugin_does"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chatDoes = (object["chat_does"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CreatePluginPromptReview(
            ok: object["ok"] as? Bool ?? false,
            summary: summary.isEmpty ? "Review finished." : summary,
            pluginDoes: pluginDoes.isEmpty ? fallbackRequest : pluginDoes,
            chatDoes: chatDoes,
            questions: questions,
            warnings: warnings
        )
    }

    private static func streamResponse(
        _ request: AgentRequest,
        model: LLMModelChoice,
        apiKey: String
    ) async throws -> String {
        switch model {
        case .gemini(let geminiModel):
            let client = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
            let (text, _) = try await collectAgentStream(client.stream(request, model: geminiModel))
            return text
        case .openai(let openAIModel):
            let client = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
            let (text, _) = try await collectAgentStream(client.stream(request, model: openAIModel))
            return text
        }
    }

    private static func resolveAPIKey(for model: LLMModelChoice) async -> String? {
        if let key = await MainActor.run(body: {
            AppSecretResolver().resolve(
                account: model.provider.secretAccount,
                environmentKeys: model.provider.apiKeyEnvironmentKeys
            )
        }), !key.isEmpty {
            return key
        }
        return TurnProcessContext.effectiveAPIKey
    }
}
