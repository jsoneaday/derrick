import Foundation
import MCP
import MCPToolCatalog
import Plugin

/// MCP entrypoint for the factory. The model supplies only the user's goal;
/// builder, runner, reviewer, compiler, and hash verification stay host-owned.
public enum PluginFactoryToolModule: MCPToolModule {
    public static let id: AllowedMCPTool = .pluginFactoryBuild

    public static var inputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "goal": .object([
                    "type": .string("string"),
                    "description": .string("What the user wants the Agent Plugin to do.")
                ])
            ]),
            "required": .array([.string("goal")])
        ])
    }

    public static func makeRegistration(
        build: @escaping @Sendable (String) async throws -> PluginFactoryRelease
    ) -> MCPToolRegistration {
        MCPToolRegistration(
            tool: id,
            description: id.defaultDescription,
            inputSchema: inputSchema
        ) { arguments in
            let goal = arguments["goal"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !goal.isEmpty else {
                return #"{"ok":false,"error":"goal is required."}"#
            }
            let release = try await build(goal)
            let summary = FactoryBuildSummary(
                pluginID: release.pluginID,
                version: release.version,
                contentHash: release.contentHash.rawValue,
                reviewSummary: release.reviewSummary
            )
            let data = try JSONEncoder().encode(summary)
            return String(decoding: data, as: UTF8.self)
        }
    }
}

private struct FactoryBuildSummary: Codable, Sendable {
    let ok = true
    let pluginID: String
    let version: String
    let contentHash: String
    let reviewSummary: String

    enum CodingKeys: String, CodingKey {
        case ok
        case pluginID = "plugin_id"
        case version
        case contentHash = "content_hash"
        case reviewSummary = "review_summary"
    }
}
