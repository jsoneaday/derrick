import Foundation
import LLMAgentClient
import MCPServer
import Plugin
import Structure

public actor LiveFactoryBuilder: PluginFactoryBuilder {
    private let apiKey: String
    private let model: OpenAIModel = .gpt56Luna

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func makeDraft(_ request: PluginFactoryBuilderRequest) async throws -> PluginFactoryDraft {
        let client = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
        let stream = client.stream(
            AgentRequest.prompt(
                Self.userPrompt(for: request),
                system: Self.builderSystemPrompt(for: request.userGoal),
                temperature: 0,
                responseSchema: Self.builderResponseSchema
            ),
            model: model
        )
        let (text, _) = try await collectAgentStream(stream)
        return try Self.decodeDraft(text)
    }

    private static func userPrompt(for request: PluginFactoryBuilderRequest) -> String {
        var sections = ["User goal:\n\(request.userGoal)"]
        if let host = request.hostManifest {
            sections.append(
                """
                The host already assigned plugin_id \(host.pluginID) and these secret ids: \
                \(host.secrets.map(\.id).joined(separator: ", ")). \
                Return go_source and test_input_json. Do not pick a different plugin_id or secret ids.
                """
            )
        }
        if let previous = request.previousDraft {
            sections.append("Previous draft:\n\(previous.guestSource)")
            let previousTestInput = String(decoding: previous.testInput, as: UTF8.self)
            if !previousTestInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append("Previous test_input_json:\n\(previousTestInput)")
            }
        }
        if let feedback = request.feedback {
            sections.append("Factory feedback to correct before the next attempt:\n\(feedback)")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func decodeDraft(_ text: String) throws -> PluginFactoryDraft {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if normalized.first == "{", normalized.last == "}" {
            jsonText = normalized
        } else if let start = normalized.firstIndex(of: "{"),
                  let end = normalized.lastIndex(of: "}") {
            jsonText = String(normalized[start...end])
        } else {
            throw HarnessError.invalidModelJSON("builder")
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw HarnessError.invalidModelJSON("builder")
        }
        return try JSONDecoder().decode(PluginFactoryBuilderResponse.self, from: data).draft()
    }

    private static func builderSystemPrompt(for userGoal: String) -> String {
        """
        You are the Derrick plugin builder. Convert the user's goal into one complete Agent Plugin draft.
        \(ScriptExecContractPrompts.pluginFactoryBuilderGuide())
        \(ConnectorContractPrompts.builderGuide(forUserGoal: userGoal))
        When vendor documentation is supplied in the user prompt, use it only to fill may_call HTTP details.
        """
    }

    private static let builderResponseSchema = AgentSchema(
        type: .object,
        properties: [
            "plugin_id": AgentSchema(type: .string),
            "version": AgentSchema(type: .string),
            "description": AgentSchema(type: .string),
            "go_source": AgentSchema(type: .string),
            "test_input_json": AgentSchema(type: .string),
            "skill_files": AgentSchema(
                type: .array,
                items: AgentSchema(
                    type: .object,
                    properties: [
                        "path": AgentSchema(type: .string),
                        "body": AgentSchema(type: .string),
                    ],
                    required: ["path", "body"]
                )
            ),
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
            "role": AgentSchema(type: .string),
            "messaging_ops": AgentSchema(type: .array, items: AgentSchema(type: .string)),
        ],
        required: [
            "plugin_id", "version", "description", "go_source",
            "test_input_json", "skill_files",
        ]
    )
}

public actor LiveFactoryReviewer: PluginFactoryReviewer {
    private let apiKey: String
    private let model: OpenAIModel = .gpt56Luna

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func review(
        draft: PluginFactoryDraft,
        directRun: PluginFactoryExecutionResult
    ) async throws -> PluginFactoryReview {
        let client = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
        let output = String(decoding: directRun.stdout, as: UTF8.self)
        let stream = client.stream(
            AgentRequest.prompt(
                """
                User goal:
                \(draft.userGoal ?? "(not supplied)")

                Manifest:
                \(draft.manifestJSON)

                test_input_json:
                \(String(decoding: draft.testInput, as: UTF8.self))

                Go source:
                \(draft.guestSource)

                Direct test output:
                \(output)
                """,
                system: Self.reviewerSystemPrompt(for: draft.userGoal),
                temperature: 0,
                responseSchema: Self.reviewerResponseSchema
            ),
            model: model
        )
        let (text, _) = try await collectAgentStream(stream)
        return try Self.decodeReview(text)
    }

    private static func reviewerSystemPrompt(for userGoal: String?) -> String {
        """
    Review the user's goal, manifest, test_input_json, exact Go source, and direct test output.
    \(ScriptExecContractPrompts.pluginFactoryReviewerGuide())
    \(ConnectorContractPrompts.reviewerGuide(forUserGoal: userGoal))
    """
    }

    private static let reviewerResponseSchema = AgentSchema(
        type: .object,
        properties: [
            "decision": AgentSchema(type: .string),
            "summary": AgentSchema(type: .string),
            "findings": AgentSchema(
                type: .array,
                items: AgentSchema(
                    type: .object,
                    properties: [
                        "severity": AgentSchema(type: .string),
                        "category": AgentSchema(type: .string),
                        "message": AgentSchema(type: .string),
                    ],
                    required: ["severity", "category", "message"]
                )
            ),
        ],
        required: ["decision", "summary", "findings"]
    )

    private static func decodeReview(_ text: String) throws -> PluginFactoryReview {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = normalized.data(using: .utf8) else {
            throw HarnessError.invalidModelJSON("reviewer")
        }
        let wire = try JSONDecoder().decode(ReviewerWire.self, from: data)
        guard let decision = PluginReviewDecision(rawValue: wire.decision) else {
            throw HarnessError.invalidModelJSON("reviewer")
        }
        let findings = wire.findings.compactMap { finding -> PluginReviewFinding? in
            guard let severity = PluginReviewSeverity(rawValue: finding.severity),
                  let category = PluginReviewCategory(rawValue: finding.category) else {
                return nil
            }
            return PluginReviewFinding(
                severity: severity,
                category: category,
                message: finding.message
            )
        }
        return PluginFactoryReview(decision: decision, findings: findings, summary: wire.summary)
    }
}

private struct ReviewerWire: Decodable {
    let decision: String
    let summary: String
    let findings: [FindingWire]
}

private struct FindingWire: Decodable {
    let severity: String
    let category: String
    let message: String
}

public enum HarnessError: Error, CustomStringConvertible {
    case missingAPIKey
    case invalidModelJSON(String)

    public var description: String {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY is not set."
        case .invalidModelJSON(let role):
            return "The \(role) returned invalid JSON."
        }
    }
}
