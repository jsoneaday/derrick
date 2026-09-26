import Foundation
import MCP
import Plugin
import Structure

/// Generic execution tools for approved factory releases. There is no
/// plugin-specific dispatch here: every release receives JSON on stdin.
public enum PluginRuntimeToolModule {
    public static func makeListRegistration(
        list: @escaping @Sendable () async throws -> [PluginFactoryReleaseSummary],
        skillIndex: @escaping @Sendable () async throws -> [PluginSkillDisclosure.IndexEntry] = { [] }
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .pluginList,
            description: AllowedMCPTool.pluginList.defaultDescription,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ) { _ in
            let releases = try await list()
            let skills = try await skillIndex()
            let payload: [String: Any] = [
                "releases": releases.map { release in
                    [
                        "plugin_id": release.pluginID,
                        "version": release.version,
                        "content_hash": release.contentHash,
                    ] as [String: String]
                },
                "skills": skills.map { entry in
                    [
                        "plugin_id": entry.pluginID,
                        "skill_name": entry.skillName,
                        "description": entry.description,
                    ] as [String: String]
                },
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
    }

    public static func makeSkillRegistration(
        activate: @escaping @Sendable (_ pluginID: String, _ skill: String) async throws -> String?,
        reference: @escaping @Sendable (_ pluginID: String, _ path: String) async throws -> (path: String, body: String)?
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .pluginSkill,
            description: AllowedMCPTool.pluginSkill.defaultDescription,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "plugin_id": .object([
                        "type": .string("string"),
                        "description": .string("Approved plugin id that owns the skill."),
                    ]),
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("activate (full SKILL.md) or reference (one references/* file)."),
                    ]),
                    "skill": .object([
                        "type": .string("string"),
                        "description": .string("Skill name or skills/<name>/SKILL.md path (required for activate)."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Reference path or filename (required for reference)."),
                    ]),
                ]),
                "required": .array([.string("plugin_id"), .string("action")]),
            ])
        ) { arguments in
            let pluginID = arguments["plugin_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let action = arguments["action"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            guard !pluginID.isEmpty else {
                return try failure(
                    stage: .validation,
                    code: "plugin_id_required",
                    message: "plugin_id is required."
                ).encodedJSON()
            }
            switch action {
            case "activate":
                let skill = arguments["skill"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !skill.isEmpty else {
                    return try failure(
                        stage: .validation,
                        code: "skill_required",
                        message: "skill is required for action=activate."
                    ).encodedJSON()
                }
                guard let body = try await activate(pluginID, skill) else {
                    return try failure(
                        stage: .validation,
                        code: "skill_not_found",
                        message: "No skill matching \(skill) on /\(pluginID)."
                    ).encodedJSON()
                }
                return try ToolExecutionOutcome.completed(
                    output: ToolExecutionOutcome.Output(format: .text, value: body)
                ).encodedJSON()
            case "reference":
                let path = arguments["path"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !path.isEmpty else {
                    return try failure(
                        stage: .validation,
                        code: "path_required",
                        message: "path is required for action=reference."
                    ).encodedJSON()
                }
                guard let hit = try await reference(pluginID, path) else {
                    let hint = "No reference matching that path on /\(pluginID)."
                    return try failure(
                        stage: .validation,
                        code: "reference_not_found",
                        message: "No reference matching \(path). \(hint)"
                    ).encodedJSON()
                }
                let payload: [String: String] = ["path": hit.path, "body": hit.body]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                return try ToolExecutionOutcome.completed(
                    output: ToolExecutionOutcome.Output(
                        format: .json,
                        value: String(decoding: data, as: UTF8.self)
                    )
                ).encodedJSON()
            default:
                return try failure(
                    stage: .validation,
                    code: "invalid_action",
                    message: "action must be activate or reference."
                ).encodedJSON()
            }
        }
    }

    public static func makeInvokeRegistration(
        invoke: @escaping @Sendable (String, Data) async throws -> PluginFactoryExecutionResult
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: .pluginInvoke,
            description: AllowedMCPTool.pluginInvoke.defaultDescription,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "plugin_id": .object([
                        "type": .string("string"),
                        "description": .string("Approved plugin id."),
                    ]),
                    "input_json": .object([
                        "type": .string("string"),
                        "description": .string("JSON object delivered to the plugin on stdin."),
                    ]),
                ]),
                "required": .array([.string("plugin_id")]),
            ])
        ) { arguments in
            let pluginID = arguments["plugin_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pluginID.isEmpty else {
                return try failure(
                    stage: .validation,
                    code: "plugin_id_required",
                    message: "plugin_id is required."
                ).encodedJSON()
            }
            let inputText = arguments["input_json"]?.stringValue ?? "{}"
            guard let input = inputText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                return try failure(
                    stage: .validation,
                    code: "invalid_input_json",
                    message: "input_json must be a JSON object."
                ).encodedJSON()
            }
            let normalizedInput = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let result: PluginFactoryExecutionResult
            do {
                result = try await invoke(pluginID, normalizedInput)
            } catch let error as PluginSecretsRequiredError {
                return try ToolExecutionOutcome.failure(
                    status: .blocked,
                    stage: .validation,
                    diagnostics: [
                        ToolExecutionOutcome.Diagnostic(
                            code: "plugin_secrets_required",
                            message: secretsRequiredJSON(error)
                        )
                    ],
                    retry: ToolExecutionOutcome.Retry(allowed: false)
                ).encodedJSON()
            } catch {
                return try failure(
                    stage: .execution,
                    code: "plugin_invoke_failed",
                    message: error.localizedDescription
                ).encodedJSON()
            }
            guard result.exitCode == 0 else {
                let diagnostic = diagnostic(from: result)
                let message = ConnectorPluginExecutionMessage.userFacing(fromDetail: diagnostic)
                    ?? "Approved plugin failed during execution (exit \(result.exitCode)): \(diagnostic)"
                return try failure(
                    stage: .execution,
                    code: "plugin_process_failed",
                    message: message
                ).encodedJSON()
            }
            do {
                let envelopes = try PluginEnvelopeList.decode(result.stdout)
                guard envelopes.contains(where: { $0.verb.classification == .terminal }) else {
                    return try failure(
                        stage: .execution,
                        code: "plugin_terminal_output_missing",
                        message: "Approved plugin returned no terminal result envelope."
                    ).encodedJSON()
                }
            } catch {
                return try failure(
                    stage: .execution,
                    code: "plugin_output_invalid",
                    message: "Approved plugin returned invalid output: \(error.localizedDescription)"
                ).encodedJSON()
            }
            return try ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(
                    format: .json,
                    value: String(decoding: result.stdout, as: UTF8.self)
                )
            ).encodedJSON()
        }
    }

    private static func failure(
        stage: ToolExecutionOutcome.Stage,
        code: String,
        message: String
    ) -> ToolExecutionOutcome {
        ToolExecutionOutcome.failure(
            stage: stage,
            diagnostics: [
                ToolExecutionOutcome.Diagnostic(code: code, message: message)
            ],
            retry: ToolExecutionOutcome.Retry(allowed: false)
        )
    }

    private static func secretsRequiredJSON(_ error: PluginSecretsRequiredError) -> String {
        let payload = PluginCredentialPromptPayload(
            pluginID: error.pluginID,
            secrets: error.fields.map(\.descriptor),
            mode: .requireMissing
        )
        if let data = try? JSONEncoder().encode(payload) {
            return String(decoding: data, as: UTF8.self)
        }
        return error.localizedDescription
    }

    private static func diagnostic(from result: PluginFactoryExecutionResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return String(stderr.prefix(2_000))
        }
        return "no diagnostic output"
    }
}
