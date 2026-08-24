import Foundation
import MCP
import MCPToolCatalog
import Plugin
import ServiceContracts

/// Generic execution tools for approved factory releases. There is no
/// plugin-specific dispatch here: every release receives JSON on stdin.
public enum PluginRuntimeToolModule {
    public static func makeListRegistration(
        list: @escaping @Sendable () async throws -> [PluginFactoryReleaseSummary]
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
            let data = try JSONEncoder().encode(releases.map { release in
                [
                    "plugin_id": release.pluginID,
                    "version": release.version,
                    "content_hash": release.contentHash,
                ]
            })
            return String(decoding: data, as: UTF8.self)
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
                return try failure(
                    stage: .execution,
                    code: "plugin_process_failed",
                    message: "Approved plugin failed during execution (exit \(result.exitCode)): \(diagnostic(from: result))"
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
            secrets: error.fields.map(\.descriptor)
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
