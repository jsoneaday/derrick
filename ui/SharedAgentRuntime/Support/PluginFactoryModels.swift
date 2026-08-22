import Foundation
import DBRepository
import LLMAgentClient
import MCPServer
import Plugin

/// Application-facing composition root. The model roles are separate objects,
/// and the factory session owns the bounded transition rules.
actor ConfiguredPluginFactoryService {
    private let repository: DBRepository
    private let settings: LLMModelSettings
    private let executor: any PluginFactoryExecutor
    private let apiKeyProvider: @Sendable () -> String?

    init(
        repository: DBRepository,
        settings: LLMModelSettings,
        executor: any PluginFactoryExecutor,
        apiKeyProvider: @escaping @Sendable () -> String? = { TurnProcessContext.effectiveAPIKey }
    ) {
        self.repository = repository
        self.settings = settings
        self.executor = executor
        self.apiKeyProvider = apiKeyProvider
    }

    func build(userGoal: String) async throws -> PluginFactoryRelease {
        let release = try await PluginFactorySession().build(
            userGoal: userGoal,
            builder: ConfiguredPluginFactoryBuilder(settings: settings, apiKeyProvider: apiKeyProvider),
            executor: executor,
            reviewer: ConfiguredPluginSafetyReviewer(settings: settings, apiKeyProvider: apiKeyProvider)
        )
        try await repository.savePluginFactoryRelease(release)
        return release
    }
}

/// Model adapter for the first half of the factory. This model translates
/// intent into data; it does not run, review, compile, or release source.
actor ConfiguredPluginFactoryBuilder: PluginFactoryBuilder {
    private let settings: LLMModelSettings
    private let apiKeyProvider: @Sendable () -> String?

    init(
        settings: LLMModelSettings,
        apiKeyProvider: @escaping @Sendable () -> String? = { TurnProcessContext.effectiveAPIKey }
    ) {
        self.settings = settings
        self.apiKeyProvider = apiKeyProvider
    }

    func makeDraft(_ request: PluginFactoryBuilderRequest) async throws -> PluginFactoryDraft {
        let model = await MainActor.run { settings.pluginBuilderModel }
        guard let apiKey = await resolveAPIKey(for: model) else {
            throw PluginFactoryModelError.missingAPIKey(model.helperDisplayName)
        }

        let response = try await stream(
            AgentRequest.prompt(
                Self.userPrompt(for: request),
                system: Self.builderSystemPrompt,
                temperature: 0,
                responseSchema: Self.builderResponseSchema
            ),
            model: model,
            apiKey: apiKey
        )
        return try Self.decodeDraft(response)
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
        return apiKeyProvider()
    }

    private func stream(
        _ request: AgentRequest,
        model: LLMModelChoice,
        apiKey: String
    ) async throws -> String {
        let stream: AsyncThrowingStream<AgentStreamEvent, Error>
        switch model {
        case .gemini(let selected):
            stream = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
                .stream(request, model: selected)
        case .openai(let selected):
            stream = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
                .stream(request, model: selected)
        }
        let (text, usage) = try await collectFactoryModelStream(stream, role: "builder")
        if let usage {
            _ = await UsageLimitsService.shared.recordAPIUsage(usage)
        }
        return text
    }

    private static let builderSystemPrompt = """
    You are the Derrick plugin builder. Convert the user's goal into one complete Agent Plugin draft.
    Return exactly one JSON object with these keys:
    plugin_id (string), version (string), description (string), swift_source (string),
    test_input_json (string), skill_files (array of objects with path and body).
    Do not return manifest_json. The host creates the canonical Agent Plugin manifest,
    including the exact `$schema` field for Agent Plugin 1.0 and the fixed
    extensions.app.derrick.entrypoint ./app.derrick/plugin.swift. The Swift source is a standalone executable run as:
    swift /tmp/plugin.swift
    It reads one JSON event from stdin and writes a JSON array of Derrick envelopes to stdout.
    To request host HTTP, emit {"verb":"http.request","request_id":"...","method":"GET","url":"https://..."}.
    The host will invoke the program again with {"kind":"http_results","http_results":[
    {"request_id":"...","status":200,"body":"...","error":null}]}.
    Only the host performs HTTP; the Swift container has no network.
    Use only the Derrick contract types shown in the source comments and never use Process, URLSession,
    sockets, shell commands, or credentials. Keep the draft small and deterministic.
    Implement the user's goal directly in the plugin. Never generate prompts, model instructions,
    or a plan for Chat/another model to perform the core function. For news goals, the plugin must
    fetch and parse the requested public feed data and emit a source-grounded result from that data.
    The direct test input must exercise the terminal result path with a matching http_results fixture,
    not only verify that request envelopes were emitted.
    The current Derrick response view supports plain text, Markdown, CSV, and sanitized HTML.
    For HTML output, put the markup in the result.emit `html` field; use `summary`, `content`, or
    `text` for plain text, Markdown, or CSV. HTML is sanitized by the host before native rendering,
    and only safe structure and http(s) links are retained. When parsing HTML or RSS, unwrap CDATA,
    strip untrusted tags, decode entities, and normalize whitespace before emitting user-facing text,
    using the same safety behavior as Derrick's shared markup sanitizer. Keep the plugin's result
    payload in its original supported format; the host does not rewrite it.
    If skill_files is not needed, return an empty array. Every skill file path must be exactly
    skills/<name>/SKILL.md, where <name> is one safe path component using letters, numbers,
    hyphens, or underscores.
    """

    private static let builderResponseSchema = AgentSchema(
        type: .object,
        properties: [
            "plugin_id": AgentSchema(type: .string),
            "version": AgentSchema(type: .string),
            "description": AgentSchema(type: .string),
            "swift_source": AgentSchema(type: .string),
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
        ],
        required: [
            "plugin_id", "version", "description", "swift_source",
            "test_input_json", "skill_files",
        ]
    )

    private static func userPrompt(for request: PluginFactoryBuilderRequest) -> String {
        var sections = ["User goal:\n\(request.userGoal)"]
        if let previous = request.previousDraft {
            sections.append("Previous draft:\n\(previous.swiftSource)")
        }
        if let feedback = request.feedback {
            sections.append("Direct-test feedback to correct once:\n\(feedback)")
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
            throw PluginFactoryModelError.invalidBuilderResponse
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw PluginFactoryModelError.invalidBuilderResponse
        }
        do {
            return try JSONDecoder()
                .decode(PluginFactoryBuilderResponse.self, from: data)
                .draft()
        } catch let error as PluginFactoryError {
            throw error
        } catch let error as PluginFactoryModelError {
            throw error
        } catch {
            throw PluginFactoryModelError.invalidBuilderResponse
        }
    }
}

/// Model adapter for the independent alignment and safety decision.
actor ConfiguredPluginSafetyReviewer: PluginFactoryReviewer {
    private let settings: LLMModelSettings
    private let apiKeyProvider: @Sendable () -> String?

    init(
        settings: LLMModelSettings,
        apiKeyProvider: @escaping @Sendable () -> String? = { TurnProcessContext.effectiveAPIKey }
    ) {
        self.settings = settings
        self.apiKeyProvider = apiKeyProvider
    }

    func review(
        draft: PluginFactoryDraft,
        directRun: PluginFactoryExecutionResult
    ) async throws -> PluginFactoryReview {
        let model = await MainActor.run { settings.pluginSafetyReviewerModel }
        guard let apiKey = await resolveAPIKey(for: model) else {
            throw PluginFactoryModelError.missingAPIKey(model.helperDisplayName)
        }
        let response = try await stream(
            AgentRequest.prompt(
                Self.userPrompt(for: draft, directRun: directRun),
                system: Self.reviewerSystemPrompt,
                temperature: 0,
                responseSchema: Self.reviewerResponseSchema
            ),
            model: model,
            apiKey: apiKey
        )
        return try Self.decodeReview(response)
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
        return apiKeyProvider()
    }

    private func stream(
        _ request: AgentRequest,
        model: LLMModelChoice,
        apiKey: String
    ) async throws -> String {
        let stream: AsyncThrowingStream<AgentStreamEvent, Error>
        switch model {
        case .gemini(let selected):
            stream = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
                .stream(request, model: selected)
        case .openai(let selected):
            stream = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
                .stream(request, model: selected)
        }
        let (text, usage) = try await collectFactoryModelStream(stream, role: "safety reviewer")
        if let usage {
            _ = await UsageLimitsService.shared.recordAPIUsage(usage)
        }
        return text
    }

    private static let reviewerSystemPrompt = """
    You are Derrick's independent plugin alignment and safety reviewer.
    Review the user's goal, manifest, exact Swift source, and direct test output.
    Return exactly one JSON object:
    {"decision":"approved|rejected","summary":"...","findings":[
      {"severity":"info|warning|blocking","category":"alignment|safety|correctness|privacy|supplyChain","message":"..."}
    ]}
    Reject unsafe, misleading, unrelated, non-deterministic, credential-seeking, or policy-bypassing code.
    Compilation success is not approval. Do not rewrite the code and do not suggest an automatic retry.
    """

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

    private static func userPrompt(
        for draft: PluginFactoryDraft,
        directRun: PluginFactoryExecutionResult
    ) -> String {
        let output = String(decoding: directRun.stdout, as: UTF8.self)
        return """
        Manifest:
        \(draft.manifestJSON)

        Swift source:
        \(draft.swiftSource)

        Direct test output:
        \(output)
        """
    }

    private static func decodeReview(_ text: String) throws -> PluginFactoryReview {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = normalized.data(using: .utf8) else {
            throw PluginFactoryModelError.invalidReviewerResponse
        }
        do {
            let wire = try JSONDecoder().decode(ReviewerWire.self, from: data)
            guard let decision = PluginReviewDecision(rawValue: wire.decision) else {
                throw PluginFactoryModelError.invalidReviewerResponse
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
            return PluginFactoryReview(
                decision: decision,
                findings: findings,
                summary: wire.summary
            )
        } catch let error as PluginFactoryModelError {
            throw error
        } catch {
            throw PluginFactoryModelError.invalidReviewerResponse
        }
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

enum PluginFactoryModelError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey(String)
    case invalidBuilderResponse
    case invalidReviewerResponse
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let model):
            return "No API key is available for \(model)."
        case .invalidBuilderResponse:
            return "The plugin builder returned invalid draft JSON."
        case .invalidReviewerResponse:
            return "The plugin safety reviewer returned invalid review JSON."
        case .timedOut(let role):
            return "The plugin \(role) model timed out."
        }
    }
}

private func collectFactoryModelStream(
    _ stream: AsyncThrowingStream<AgentStreamEvent, Error>,
    role: String
) async throws -> (text: String, usage: AgentTokenUsage?) {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, AgentTokenUsage?), Error>) in
        let reply = FactoryModelReplyOnce(continuation)
        let worker = Task {
            do {
                reply.resume(returning: try await collectAgentStream(stream))
            } catch {
                reply.resume(throwing: error)
            }
        }
        Task {
            do {
                try await Task.sleep(nanoseconds: 120_000_000_000)
            } catch {
                return
            }
            worker.cancel()
            reply.resume(throwing: PluginFactoryModelError.timedOut(role))
        }
    }
}

private final class FactoryModelReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(String, AgentTokenUsage?), Error>?

    init(_ continuation: CheckedContinuation<(String, AgentTokenUsage?), Error>) {
        self.continuation = continuation
    }

    func resume(returning result: (String, AgentTokenUsage?)) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
