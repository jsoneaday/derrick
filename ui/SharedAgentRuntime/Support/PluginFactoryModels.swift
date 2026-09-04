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
    private let logger: PluginFactoryLogger
    private let apiKeyProvider: @Sendable () -> String?

    init(
        repository: DBRepository,
        settings: LLMModelSettings,
        executor: any PluginFactoryExecutor,
        logger: @escaping PluginFactoryLogger = { _ in },
        apiKeyProvider: @escaping @Sendable () -> String? = { TurnProcessContext.effectiveAPIKey }
    ) {
        self.repository = repository
        self.settings = settings
        self.executor = executor
        self.logger = logger
        self.apiKeyProvider = apiKeyProvider
    }

    func build(userGoal: String) async throws -> PluginFactoryRelease {
        let existingReleases = try await repository.listPluginFactoryReleaseSummaries()
        let release = try await PluginFactorySession().build(
            userGoal: userGoal,
            builder: ConfiguredPluginFactoryBuilder(
                settings: settings,
                existingReleases: existingReleases,
                apiKeyProvider: apiKeyProvider
            ),
            executor: executor,
            reviewer: ConfiguredPluginSafetyReviewer(settings: settings, apiKeyProvider: apiKeyProvider),
            logger: logger
        )
        try await repository.savePluginFactoryRelease(release)
        return release
    }
}

/// Model adapter for the first half of the factory. This model translates
/// intent into data; it does not run, review, compile, or release source.
actor ConfiguredPluginFactoryBuilder: PluginFactoryBuilder {
    private let settings: LLMModelSettings
    private let existingReleases: [PluginFactoryReleaseSummary]
    private let apiKeyProvider: @Sendable () -> String?

    init(
        settings: LLMModelSettings,
        existingReleases: [PluginFactoryReleaseSummary] = [],
        apiKeyProvider: @escaping @Sendable () -> String? = { TurnProcessContext.effectiveAPIKey }
    ) {
        self.settings = settings
        self.existingReleases = existingReleases
        self.apiKeyProvider = apiKeyProvider
    }

    func makeDraft(_ request: PluginFactoryBuilderRequest) async throws -> PluginFactoryDraft {
        let model = await MainActor.run { settings.pluginBuilderModel }
        guard let apiKey = await resolveAPIKey(for: model) else {
            throw PluginFactoryModelError.missingAPIKey(model.helperDisplayName)
        }

        let response = try await stream(
            AgentRequest.prompt(
                Self.userPrompt(for: request, existingReleases: existingReleases),
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

    private static let builderSystemPrompt: String = {
        """
        You are the Derrick plugin builder. Convert the user's goal into one complete Agent Plugin draft.
        Return exactly one JSON object with these keys:
        plugin_id (string), version (string), description (string), python_source (string),
        test_input_json (string containing valid JSON — a serialized object, not prose),
        skill_files (array of objects with path and body),
        secrets (array of objects with id, label, and kind; optional),
        role (string, optional: "connector" or "standard").
        plugin_id must use lowercase letters, numbers, hyphens, and dots only
        (for example my-connector). Never use underscores in plugin_id.
        If the plugin needs a username, password, token, or API key, declare them in secrets.
        kind must be username, password, token, or api_key. id is a stable Keychain key
        such as username or bot_token. label is the text shown when the user saves the value.
        Never put real credentials in python_source.
        Set role to "connector" when the plugin sends and receives messages with an external
        messaging service (any chat or mail connector). Omit role or use "standard" otherwise.
        The host lists connector plugins under Messaging. Do not guess this from the plugin_id.
        Do not return manifest_json. The host creates the canonical Agent Plugin manifest,
        including the exact `$schema` field for Agent Plugin 1.0 and the fixed
        extensions.app.derrick.entrypoint ./app.derrick/plugin.py.
        \(DerrickGuestPython.modelContract)
        \(ConnectorMessagingContract.hostContract)
        Before returning the draft, self-check the implementation:
        - Sort every returned collection by an explicit stable key after parsing and de-duplicate it.
        - Match host responses by the emitted request_id.
        - Use only the Python standard library (no pip, requests, urllib, socket, or subprocess).
        - The direct test input must exercise the terminal result path with matching http_results fixtures.
        If skill_files is not needed, return an empty array. Every skill file path must be exactly
        skills/<name>/SKILL.md.
        For messaging connector plugins (role connector) that call a vendor HTTP API:
        - Declare secrets in the manifest only. Never hard-code credentials.
        - Parse each http_results body as JSON when the vendor returns JSON.
        - Paginate with vendor cursors when listing conversations or messages.
        - test_input_json http_results must exercise success, auth failure, send, read, and pagination
          when the vendor API supports those operations.
        - test_input_json must be a single JSON object serialized as a string (valid JSON.parse input).
        When vendor documentation is supplied in the user prompt, follow it exactly.
        """
    }()

    private static let builderResponseSchema = AgentSchema(
        type: .object,
        properties: [
            "plugin_id": AgentSchema(type: .string),
            "version": AgentSchema(type: .string),
            "description": AgentSchema(type: .string),
            "python_source": AgentSchema(type: .string),
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
        ],
        required: [
            "plugin_id", "version", "description", "python_source",
            "test_input_json", "skill_files",
        ]
    )

    private static func userPrompt(
        for request: PluginFactoryBuilderRequest,
        existingReleases: [PluginFactoryReleaseSummary]
    ) -> String {
        var sections = ["User goal:\n\(request.userGoal)"]
        if !existingReleases.isEmpty {
            let catalog = existingReleases
                .map { "\($0.pluginID)@\($0.version)" }
                .joined(separator: "\n")
            sections.append(
                """
                Existing released plugin versions:
                \(catalog)
                Choose a version that is not already released for the plugin_id you return.
                If reusing an existing plugin_id, increment its semantic patch version.
                """
            )
        }
        if let previous = request.previousDraft {
            sections.append("Previous draft:\n\(previous.guestSource)")
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
    Review the user's goal, manifest, exact Python source, and direct test output.
    Return exactly one JSON object:
    {"decision":"approved|rejected","summary":"...","findings":[
      {"severity":"info|warning|blocking","category":"alignment|safety|correctness|privacy|supplyChain","message":"..."}
    ]}
    Reject unsafe, misleading, unrelated, non-deterministic, credential-seeking, or policy-bypassing code.
    Apply these checks from observable evidence:
    - A deterministic result uses stable sorting and de-duplication and does not depend on response order, current time, randomness, or UUIDs.
    - Source-derived headline titles may be fragments; only generated explanatory summaries must be complete sentences when the manifest requires prose.
    - `result.emit.html` is an allowed output format. Derrick sanitizes it with an allowlist before rendering. Reject executable script behavior or a deliberate sanitizer bypass, not ordinary safe HTML tags.
    - Reject missing source-grounded parsing or claims that the direct test output does not support.
    - For connector plugins: reject code that ignores documented auth/error fields, skips required
      pagination while implying completeness, or uses test fixtures that do not cover the vendor
      operations declared in the user goal.
    Compilation success is not approval. Do not rewrite the code or approve a draft that fails these checks.
    Reject Swift source, socket/urllib/requests usage, or missing stdin reads.
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
        User goal:
        \(draft.userGoal ?? "(not supplied)")

        Manifest:
        \(draft.manifestJSON)

        Python source:
        \(draft.guestSource)

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
