import Foundation
import LLMAgentClient
import Structure

/// Classifies vendor auth from a short docs crawl using the plugin safety reviewer model.
enum ConnectorAuthClassifier {
    static func classify(
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        crawlSummary: String,
        apiKey: String,
        reviewerModelJSON: String?
    ) async throws -> ConnectorAuthDiscovery {
        let model = resolveModel(reviewerModelJSON)
        let thinking = model.resolvedThinkingOption(id: thinkingID(reviewerModelJSON))
        let clientStream: AsyncThrowingStream<AgentStreamEvent, Error>
        switch model {
        case .gemini(let selected):
            clientStream = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
                .stream(
                    AgentRequest.prompt(
                        userPrompt(vendor: vendor, crawlSummary: crawlSummary),
                        system: systemPrompt,
                        temperature: 0,
                        responseSchema: responseSchema,
                        thinking: thinking
                    ),
                    model: selected
                )
        case .openai(let selected):
            clientStream = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
                .stream(
                    AgentRequest.prompt(
                        userPrompt(vendor: vendor, crawlSummary: crawlSummary),
                        system: systemPrompt,
                        temperature: 0,
                        responseSchema: responseSchema,
                        thinking: thinking
                    ),
                    model: selected
                )
        }
        let (text, _) = try await collectFactoryModelStream(clientStream, role: "auth classifier")
        return try decode(text, crawlSummary: crawlSummary)
    }

    static func classifyOrFallback(
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        crawlSummary: String,
        apiKey: String?,
        reviewerModelJSON: String?
    ) async -> ConnectorAuthDiscovery {
        if let apiKey, !apiKey.isEmpty {
            if let classified = try? await classify(
                vendor: vendor,
                crawlSummary: crawlSummary,
                apiKey: apiKey,
                reviewerModelJSON: reviewerModelJSON
            ) {
                return classified
            }
        }
        if vendor == .slack {
            return (try? ConnectorAuthDiscovery.slackBotTokenFallback(crawlSummary: crawlSummary))
                ?? ConnectorAuthDiscovery(
                    authScheme: .botToken,
                    secrets: [PluginSecretField.slackBotToken],
                    crawlSummary: crawlSummary
                )
        }
        return ConnectorAuthDiscovery(
            authScheme: .apiKey,
            secrets: [PluginSecretField.slackBotToken],
            crawlSummary: crawlSummary
        )
    }

    private static func resolveModel(_ json: String?) -> LLMModelChoice {
        guard let json,
              let wire = try? HelperModelWire.decodeJSON(json)
        else {
            return .openai(.gpt56Luna)
        }
        switch wire.provider {
        case LLMProviderChoice.openai.rawValue:
            if let model = OpenAIModel(rawValue: wire.model) { return .openai(model) }
        case LLMProviderChoice.google.rawValue:
            if let model = GeminiModel(rawValue: wire.model) { return .gemini(model) }
        default:
            break
        }
        return .openai(.gpt56Luna)
    }

    private static func thinkingID(_ json: String?) -> String? {
        (try? json.flatMap(HelperModelWire.decodeJSON))?.thinkingID
    }

    private static let systemPrompt = """
    You classify how a messaging vendor authenticates HTTP API calls for a bot or app.
    Return exactly one JSON object with keys:
    auth_scheme, secrets, permissions, setup_hint.
    auth_scheme must be one of: bot_token, api_key, basic, oauth.
    secrets is an array of {id, label, kind}. kind is username, password, token, or api_key.
    permissions is an array of short vendor permission or scope labels only (no sentences).
    setup_hint is one short paragraph for the user, or empty.
    Do not invent implementation details or HTTP URLs.
    If the vendor is Slack, prefer auth_scheme bot_token and secret id bot_token.
    """

    private static func userPrompt(
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        crawlSummary: String
    ) -> String {
        """
        Vendor: \(vendor.displayName)
        Authentication documentation notes:
        \(crawlSummary.isEmpty ? "(none)" : crawlSummary)
        """
    }

    private static let responseSchema = AgentSchema(
        type: .object,
        properties: [
            "auth_scheme": AgentSchema(type: .string),
            "secrets": AgentSchema(
                type: .array,
                items: AgentSchema(
                    type: .object,
                    properties: [
                        "id": AgentSchema(type: .string),
                        "label": AgentSchema(type: .string),
                        "kind": AgentSchema(type: .string),
                    ],
                    required: ["id", "label", "kind"]
                )
            ),
            "permissions": AgentSchema(type: .array, items: AgentSchema(type: .string)),
            "setup_hint": AgentSchema(type: .string),
        ],
        required: ["auth_scheme", "secrets", "permissions"]
    )

    private static func decode(_ text: String, crawlSummary: String) throws -> ConnectorAuthDiscovery {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = normalized.data(using: .utf8) else {
            throw PluginFactoryModelError.invalidBuilderResponse
        }
        let decoded = try JSONDecoder().decode(ConnectorAuthDiscovery.self, from: data)
        return decoded.withCrawlSummary(crawlSummary)
    }
}
