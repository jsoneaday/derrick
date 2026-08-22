import Foundation
import MCP
import MCPToolCatalog
import Plugin

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
                return #"{"ok":false,"error":"plugin_id is required."}"#
            }
            let inputText = arguments["input_json"]?.stringValue ?? "{}"
            guard let input = inputText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                return #"{"ok":false,"error":"input_json must be a JSON object."}"#
            }
            let normalizedInput = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let result = try await invoke(pluginID, normalizedInput)
            return String(decoding: result.stdout, as: UTF8.self)
        }
    }
}
